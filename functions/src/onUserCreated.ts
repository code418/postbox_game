import "./adminInit";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions/v1";
import { containsProfanity } from "./_profanityFilter";

export function sanitiseName(name: string, uid: string): string {
  const t = name.trim();
  if (t.length < 2 || t.length > 30) return `Player_${uid.slice(0, 6)}`;
  if (containsProfanity(t)) return `Player_${uid.slice(0, 6)}`;
  return t;
}

export const onUserCreated = functions.auth.user().onCreate(async (user) => {
  const raw =
    user.displayName ||
    (user.email
      ? user.email.split("@")[0]
      : `Player_${user.uid.slice(0, 6)}`);
  const displayName = sanitiseName(raw, user.uid);

  // Email is intentionally not stored in the public-readable users document;
  // it is only accessible via Firebase Auth to prevent other authenticated
  // users from reading it through friend/leaderboard name lookups.
  //
  // Use a transaction that only writes fields the user doc doesn't already
  // have. The auth trigger is asynchronous: a fast client can call
  // startScoring or updateDisplayName before this trigger commits, in which
  // case those callables already created the user doc with real values
  // (dailyPoints > 0, lifetimePoints > 0, custom displayName). A naive
  // set({...}, {merge:true}) would overwrite those with zeros and the
  // sanitised email-prefix name. Per-field merge avoids that without losing
  // initialisation for the common case where this trigger commits first.
  const userRef = admin.firestore().collection("users").doc(user.uid);
  const defaults: Record<string, unknown> = {
    displayName,
    createdAt: admin.firestore.Timestamp.now(),
    notificationPrefs: {
      friendFirstScore: true,
      friendOvertakes: true,
      addedAsFriend: true,
    },
    // Initialise all numeric fields to 0 so Firestore queries that sort or
    // compare on these fields include new users before their first claim,
    // and so the friends leaderboard shows 0 rather than "missing" for a
    // user who hasn't yet claimed in the current period.
    dailyPoints: 0,
    weeklyPoints: 0,
    monthlyPoints: 0,
    lifetimePoints: 0,
    uniquePostboxesClaimed: 0,
    streak: 0,
    maxDailyPoints: 0,
  };
  try {
    await admin.firestore().runTransaction(async (tx) => {
      const snap = await tx.get(userRef);
      const existing = snap.data() ?? {};
      const writes: Record<string, unknown> = {};
      for (const [k, v] of Object.entries(defaults)) {
        if (existing[k] === undefined) writes[k] = v;
      }
      if (Object.keys(writes).length === 0) return;
      tx.set(userRef, writes, { merge: true });
    });
  } catch (err) {
    console.error("onUserCreated: failed to write user document:", err);
    throw err; // Re-throw so Firebase retries the trigger.
  }
});
