import "./adminInit";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import { getTodayLondon } from "./_dateUtils";
import { updateUserLeaderboards, mergeLifetimeEntries, LifetimeLeaderboardEntry } from "./_leaderboardUtils";
import { containsProfanity } from "./_profanityFilter";

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
  if (name.length < 2) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Name must be at least 2 characters"
    );
  }
  if (name.length > 30) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Name must be 30 characters or fewer"
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
  // Look up the user's avatar so the leaderboard refresh carries it through
  // alongside the new display name; otherwise a name change would strip avatar
  // from period entries until the user's next claim rewrote them.
  const userSnapForAvatar = await admin.firestore()
    .collection("users")
    .doc(uid)
    .get();
  const avatarForLeaderboard =
    userSnapForAvatar.data()?.avatar as Record<string, number> | undefined;
  await updateUserLeaderboards(uid, name, today, admin.firestore(), avatarForLeaderboard);

  // Read user doc and update lifetime leaderboard atomically in one transaction
  // so a concurrent startScoring claim cannot race between our read of
  // uniquePostboxesClaimed/lifetimePoints and our write to leaderboards/lifetime.
  try {
    const db = admin.firestore();
    const userRef = db.collection("users").doc(uid);
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
      const avatarInTx = (d.avatar as Record<string, number> | undefined) ?? avatarForLeaderboard;
      const updated = mergeLifetimeEntries(existing, uid, name, uniquePostboxesClaimed, lifetimePoints, 100, avatarInTx);
      tx.set(lifetimeRef, { periodKey: "lifetime", entries: updated }, { merge: false });
    });
  } catch (lifetimeErr) {
    console.error("lifetime leaderboard display name update failed (non-fatal):", lifetimeErr);
  }

  return { displayName: name };
});
