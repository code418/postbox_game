import "./adminInit";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import * as functionsV1 from "firebase-functions/v1";

const database = admin.firestore();

// ── Pure helpers (exported for unit testing) ──────────────────────────────

/**
 * Returns the updated fcmTokens array after adding `token`.
 * Deduplicates and caps at `max` (dropping the oldest when over).
 */
export function updateFcmTokens(existing: string[], token: string, max = 5): string[] {
  if (existing.includes(token)) return existing;
  const updated = [...existing, token];
  return updated.length > max ? updated.slice(updated.length - max) : updated;
}

/**
 * Returns UIDs present in `after` but not in `before`.
 */
export function diffFriends(before: string[], after: string[]): string[] {
  const beforeSet = new Set(before);
  return after.filter((f) => !beforeSet.has(f));
}

// ── Internal FCM send helper ──────────────────────────────────────────────

/**
 * Sends a push notification to all valid FCM tokens registered for `uid`.
 * Prunes any tokens that FCM reports as no longer registered.
 *
 * Tokens are stored in a separate `fcmTokens/{uid}` collection rather than
 * on the user document so they are not exposed to other authenticated users
 * through the world-readable `users/{uid}` Firestore rules.
 */
async function sendToUser(uid: string, title: string, body: string): Promise<void> {
  const doc = await database.collection("fcmTokens").doc(uid).get();
  const tokens: string[] = (doc.data()?.tokens as string[] | undefined) ?? [];
  if (tokens.length === 0) return;

  const response = await admin.messaging().sendEachForMulticast({
    tokens,
    notification: { title, body },
  });

  const staleTokens: string[] = [];
  response.responses.forEach((r, idx) => {
    if (
      !r.success &&
      r.error?.code === "messaging/registration-token-not-registered"
    ) {
      staleTokens.push(tokens[idx]);
    }
  });

  if (staleTokens.length > 0) {
    await database.collection("fcmTokens").doc(uid).update({
      tokens: admin.firestore.FieldValue.arrayRemove(...staleTokens),
    });
  }
}

// ── Notification event functions ──────────────────────────────────────────

/**
 * Notifies `uid`'s friends who haven't yet scored today that they were beaten
 * to the first claim. Skips friends who already have dailyPoints > 0.
 *
 * Call only when `uid` is making their first claim of the day
 * (i.e. userClaimsSnap.docs.length === 0 in startScoring).
 */
export async function notifyFriendsFirstClaim(
  uid: string,
  displayName: string
): Promise<void> {
  const userDoc = await database.collection("users").doc(uid).get();
  const friends: string[] = (userDoc.data()?.friends as string[] | undefined) ?? [];
  if (friends.length === 0) return;

  const friendDocs = await Promise.all(
    friends.map((fuid) => database.collection("users").doc(fuid).get())
  );

  // If any friend has already scored today the claimant is not first — abort.
  const anyFriendScoredToday = friendDocs.some(
    (doc) => ((doc.data()?.dailyPoints as number | undefined) ?? 0) > 0
  );
  if (anyFriendScoredToday) return;

  await Promise.allSettled(
    friendDocs.map(async (doc) => {
      const prefs = doc.data()?.notificationPrefs as
        | Record<string, boolean>
        | undefined;
      if (prefs?.friendFirstScore === false) return;
      await sendToUser(
        doc.id,
        "First find of the day!",
        `${displayName} was the first of your friends to find a postbox today!`
      );
    })
  );
}

/**
 * Notifies friends in `uid`'s list whose dailyPoints are below `newDailyPoints`.
 * This is the "someone just overtook you" notification.
 */
export async function notifyFriendOvertake(
  uid: string,
  displayName: string,
  newDailyPoints: number
): Promise<void> {
  const userDoc = await database.collection("users").doc(uid).get();
  const friends: string[] = (userDoc.data()?.friends as string[] | undefined) ?? [];
  if (friends.length === 0) return;

  const friendDocs = await Promise.all(
    friends.map((fuid) => database.collection("users").doc(fuid).get())
  );

  await Promise.allSettled(
    friendDocs.map(async (doc) => {
      const fdata = doc.data();
      if (!fdata) return;
      const friendDaily = (fdata.dailyPoints as number | undefined) ?? 0;
      // Only notify for genuine overtakes — skip friends who haven't scored yet.
      if (friendDaily === 0 || newDailyPoints <= friendDaily) return;
      const prefs = fdata.notificationPrefs as
        | Record<string, boolean>
        | undefined;
      if (prefs?.friendOvertakes === false) return;
      await sendToUser(
        doc.id,
        "Overtaken!",
        `${displayName} just overtook you on today's leaderboard!`
      );
    })
  );
}

/**
 * Notifies `newFriendUid` that `adderDisplayName` added them as a friend.
 */
export async function notifyFriendOfAddition(
  newFriendUid: string,
  adderDisplayName: string
): Promise<void> {
  const doc = await database.collection("users").doc(newFriendUid).get();
  const prefs = doc.data()?.notificationPrefs as
    | Record<string, boolean>
    | undefined;
  if (prefs?.addedAsFriend === false) return;
  await sendToUser(
    newFriendUid,
    "New friend!",
    `${adderDisplayName} added you as a friend.`
  );
}

// ── Callable: register device FCM token ──────────────────────────────────

export const registerFcmToken = functions.https.onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Must be signed in to register a notification token"
    );
  }
  const token = (request.data as { token?: unknown })?.token;
  if (typeof token !== "string" || token.length === 0) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "token must be a non-empty string"
    );
  }

  const tokenRef = database.collection("fcmTokens").doc(uid);
  const tokenDoc = await tokenRef.get();
  const existing: string[] = (tokenDoc.data()?.tokens as string[] | undefined) ?? [];
  const updated = updateFcmTokens(existing, token);

  // updateFcmTokens returns the same array reference when token already exists.
  if (updated === existing) return;
  await tokenRef.set({ tokens: updated }, { merge: true });
});

// ── Firestore trigger: friend added ──────────────────────────────────────

export const onFriendAdded = functionsV1.firestore
  .document("users/{uid}")
  .onUpdate(async (change, context) => {
    const uid: string = context.params.uid;
    const before: string[] =
      (change.before.data()?.friends as string[] | undefined) ?? [];
    const after: string[] =
      (change.after.data()?.friends as string[] | undefined) ?? [];

    const newFriends = diffFriends(before, after);
    if (newFriends.length === 0) return;

    const adderDisplayName =
      (change.after.data()?.displayName as string | undefined) ||
      `Player_${uid.slice(0, 6)}`;

    await Promise.allSettled(
      newFriends.map((fuid) => notifyFriendOfAddition(fuid, adderDisplayName))
    );
  });
