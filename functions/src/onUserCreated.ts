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
  await admin.firestore().collection("users").doc(user.uid).set(
    {
      displayName,
      createdAt: admin.firestore.Timestamp.now(),
      notificationPrefs: {
        friendFirstScore: true,
        friendOvertakes: true,
        addedAsFriend: true,
      },
    },
    { merge: true }
  );
});
