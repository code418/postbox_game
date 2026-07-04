import "./adminInit";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions/v1";
import { FUNCTION_REGION } from "./_region";
import { getTodayLondon } from "./_dateUtils";
import {
  anonymiseClaimsForUser,
  anonymiseReportsForUser,
  removeUserFromLeaderboards,
  removeUserFromFriends,
  deleteUserDocs,
} from "./_accountDeletion";

const db = admin.firestore();

/**
 * onUserDeleted — GDPR right-to-erasure cleanup.
 *
 * Fires when an Auth user is deleted (the in-app "Delete account" flow calls
 * User.delete() after re-auth). Auth triggers are global, so this stays on
 * FUNCTION_REGION (europe-west2), mirroring onUserCreated.
 *
 * Self-contained (no Delete-User-Data extension): owns all Firestore + Storage
 * cleanup. Claims and reports are ANONYMISED (PII stripped, record kept) to
 * preserve global claim/postbox-history integrity; everything else is deleted.
 *
 * Best-effort: the Auth user is already gone, so each phase is independent and
 * a failure in one must not abort the rest. Failures are logged, not thrown.
 */
export const onUserDeleted = functions
  .region(FUNCTION_REGION)
  .auth.user()
  .onDelete(async (user) => {
    const uid = user.uid;

    // Capture the user's county slugs BEFORE any deletion — deleteUserDocs (run
    // last) removes the countyStats subcollection that tells us which per-county
    // leaderboards to scrub.
    let countySlugs: string[] = [];
    try {
      const cs = await db.collection("users").doc(uid).collection("countyStats").get();
      countySlugs = cs.docs.map((d) => d.id);
    } catch (e) {
      console.error(`onUserDeleted: countyStats read failed for ${uid} (non-fatal):`, e);
    }

    const phases: Array<[string, Promise<unknown>]> = [
      ["anonymiseClaims", anonymiseClaimsForUser(db, uid)],
      ["anonymiseReports", anonymiseReportsForUser(db, uid)],
      ["removeFromLeaderboards", removeUserFromLeaderboards(db, uid, countySlugs)],
      ["removeFromFriends", removeUserFromFriends(db, uid)],
      ["deleteReportPhotos", deleteReportPhotos(uid)],
    ];
    const results = await Promise.allSettled(phases.map(([, p]) => p));
    results.forEach((r, i) => {
      if (r.status === "rejected") {
        console.error(`onUserDeleted: ${phases[i][0]} failed for ${uid} (non-fatal):`, r.reason);
      }
    });

    // Delete the user's own docs last so countyStats stayed readable above.
    try {
      await deleteUserDocs(db, uid);
    } catch (e) {
      console.error(`onUserDeleted: deleteUserDocs failed for ${uid} (non-fatal):`, e);
    }

    // Audit counter — one doc per London day, for internal visibility.
    try {
      await db.collection("deletions").doc(getTodayLondon()).set(
        {
          count: admin.firestore.FieldValue.increment(1),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    } catch (e) {
      console.error(`onUserDeleted: audit write failed for ${uid} (non-fatal):`, e);
    }
  });

/** Recursively delete the user's uploaded report photos from Storage. */
async function deleteReportPhotos(uid: string): Promise<void> {
  await admin.storage().bucket().deleteFiles({ prefix: `report_photos/${uid}/` });
}
