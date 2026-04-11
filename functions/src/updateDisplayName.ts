import "./adminInit";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions";

// Keep in sync with validators.dart and onUserCreated.ts.
const BLOCKED_WORDS = [
  "fuck","shit","cunt","bitch","bastard","asshole","arsehole",
  "twat","prick","cock","dick","pussy","wank","wanker",
  "bollocks","bellend","tosser","shite","knobhead","knobend",
  "gobshite","minge","slag","slapper","slut","whore",
  "bugger","arse","pillock","plonker","numpty","muppet",
  "nigger","nigga","chink","spic","kike","faggot","retard",
  "paki","spaz","mong","nonce",
];

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
  if (BLOCKED_WORDS.some((w) => name.toLowerCase().includes(w))) {
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

  return { displayName: name };
});
