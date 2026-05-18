import "./adminInit";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import { getTodayLondon } from "./_dateUtils";
import { updateUserLeaderboards, mergeLifetimeEntries, LifetimeLeaderboardEntry } from "./_leaderboardUtils";
import {
  containsProfanity,
  MIN_DISPLAY_NAME_CHARS,
  MAX_DISPLAY_NAME_CHARS,
} from "./_profanityFilter";

/**
 * Validates and updates the caller's display name in both Firebase Auth and
 * Firestore. Server-side validation mirrors client-side Validators.dart so
 * the profanity filter cannot be bypassed by calling Firestore directly.
 *
 * Returns { displayName: string } on success.
 * Throws invalid-argument if the name fails validation.
 */
export const updateDisplayName = functions.https.onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Must be signed in to update display name"
    );
  }

  const raw = (request.data as { name?: unknown })?.name;
  if (typeof raw !== "string" || raw.trim().length === 0) {
    throw new functions.https.HttpsError("invalid-argument", "name is required");
  }

  const name = raw.trim();
  if (name.length < MIN_DISPLAY_NAME_CHARS) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      `Name must be at least ${MIN_DISPLAY_NAME_CHARS} characters`
    );
  }
  if (name.length > MAX_DISPLAY_NAME_CHARS) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      `Name must be ${MAX_DISPLAY_NAME_CHARS} characters or fewer`
    );
  }
  if (containsProfanity(name)) {
    throw new functions.https.HttpsError("invalid-argument", "That name isn't allowed");
  }

  // Update both Auth profile and Firestore atomically-enough: both are
  // fire-and-forget from the user's perspective; if Firestore fails we still
  // want Auth updated, so use allSettled and re-throw only on Auth failure.
  const [authResult, fsResult] = await Promise.allSettled([
    admin.auth().updateUser(uid, { displayName: name }),
    admin.firestore()
      .collection("users")
      .doc(uid)
      .set({ displayName: name }, { merge: true }),
  ]);

  if (authResult.status === "rejected") {
    console.error("Auth updateUser failed:", authResult.reason);
    throw new functions.https.HttpsError(
      "internal",
      "Failed to update display name. Please try again."
    );
  }
  if (fsResult.status === "rejected") {
    // Non-fatal: Auth profile was updated. Log and continue so the client
    // doesn't think the operation failed when the Auth change succeeded.
    console.error("Firestore displayName update failed:", fsResult.reason);
  }

  // Refresh leaderboard entries so the new name shows immediately on
  // all periods, without waiting for the user's next claim.
  // updateUserLeaderboards uses allSettled and never throws; period
  // failures are logged inside it.
  const today = getTodayLondon();
  await updateUserLeaderboards(uid, name, today, admin.firestore());

  // Read user doc and update lifetime leaderboard atomically in one transaction
  // so a concurrent startScoring claim cannot race between our read of
  // uniquePostboxesClaimed/lifetimePoints and our write to leaderboards/lifetime.
  const db = admin.firestore();
  const userRef = db.collection("users").doc(uid);
  try {
    const lifetimeRef = db.collection("leaderboards").doc("lifetime");
    await db.runTransaction(async (tx) => {
      const [userSnap, lifetimeSnap] = await Promise.all([
        tx.get(userRef),
        tx.get(lifetimeRef),
      ]);
      const d = userSnap.data() ?? {};
      const uniquePostboxesClaimed = ((d.uniquePostboxesClaimed as number | undefined) ?? 0);
      const lifetimePoints = ((d.lifetimePoints as number | undefined) ?? 0);
      const existing = (lifetimeSnap.data()?.entries ?? []) as LifetimeLeaderboardEntry[];
      const updated = mergeLifetimeEntries(existing, uid, name, uniquePostboxesClaimed, lifetimePoints);
      tx.set(lifetimeRef, { periodKey: "lifetime", entries: updated }, { merge: false });
    });
  } catch (lifetimeErr) {
    console.error("lifetime leaderboard display name update failed (non-fatal):", lifetimeErr);
  }

  // Refresh per-county lifetime leaderboards so the user's old display name
  // doesn't linger in counties they claimed before renaming. Without this, the
  // county heatmap and user profile would show stale names until the user's
  // next claim in each affected county. One transaction per county the user
  // has stats in — bounded by the user's footprint, not the global county set.
  try {
    const statsSnap = await userRef.collection("countyStats").get();
    if (!statsSnap.empty) {
      const countyResults = await Promise.allSettled(
        statsSnap.docs.map((statsDoc) => {
          const slug = statsDoc.id;
          const lbRef = db.collection("leaderboards")
            .doc("lifetime_by_county").collection("counties").doc(slug);
          const statsRef = userRef.collection("countyStats").doc(slug);
          return db.runTransaction(async (tx) => {
            const [freshStatsSnap, lbSnap] = await Promise.all([
              tx.get(statsRef),
              tx.get(lbRef),
            ]);
            const stats = freshStatsSnap.data();
            if (!stats) return; // county stats was deleted between reads
            const unique = (stats.uniquePostboxesClaimed as number | undefined) ?? 0;
            const total = (stats.totalPoints as number | undefined) ?? 0;
            const existing = (lbSnap.data()?.entries ?? []) as LifetimeLeaderboardEntry[];
            const updated = mergeLifetimeEntries(existing, uid, name, unique, total);
            tx.set(lbRef, {
              county: stats.county ?? lbSnap.data()?.county,
              entries: updated,
            }, { merge: false });
          });
        })
      );
      for (const r of countyResults) {
        if (r.status === "rejected") {
          console.error("county lifetime leaderboard rename failed (non-fatal):", r.reason);
        }
      }
    }
  } catch (countyErr) {
    console.error("county leaderboard display name refresh failed (non-fatal):", countyErr);
  }

  return { displayName: name };
});
