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

// ── Notification eligibility helpers (exported for unit testing) ─────────

type UserData = Record<string, unknown> | undefined;

/**
 * Returns true if a friend should receive the "first claim of the day"
 * notification. False when the friend has already scored today (dailyPoints > 0)
 * or has explicitly disabled the notification.
 */
export function shouldNotifyFirstClaim(fdata: UserData): boolean {
  if (((fdata?.dailyPoints as number | undefined) ?? 0) > 0) return false;
  const prefs = fdata?.notificationPrefs as Record<string, boolean> | undefined;
  if (prefs?.friendFirstScore === false) return false;
  return true;
}

/**
 * Returns true if a friend should receive the "overtaken" notification.
 *
 * Fires only when this claim crossed the threshold: `prevDailyPoints <= friendDaily`
 * AND `newDailyPoints > friendDaily`. Without the prev check, a user already ahead
 * of a friend would re-trigger the notification on every subsequent claim of the day.
 *
 * Returns false when the friend hasn't scored yet (dailyPoints === 0), the user
 * was already ahead before this claim, the new score doesn't exceed the friend's
 * score, or the friend has disabled the notification.
 */
export function shouldNotifyOvertake(
  fdata: UserData,
  prevDailyPoints: number,
  newDailyPoints: number
): boolean {
  if (!fdata) return false;
  const friendDaily = (fdata.dailyPoints as number | undefined) ?? 0;
  if (friendDaily === 0 || newDailyPoints <= friendDaily) return false;
  // Already ahead before this claim — notification already fired (or should have).
  if (prevDailyPoints > friendDaily) return false;
  const prefs = fdata.notificationPrefs as Record<string, boolean> | undefined;
  if (prefs?.friendOvertakes === false) return false;
  return true;
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

  await Promise.allSettled(
    friendDocs.map(async (doc) => {
      const fdata = doc.data();
      if (!shouldNotifyFirstClaim(fdata)) return;
      await sendToUser(
        doc.id,
        "First find of the day!",
        `${displayName} was the first of your friends to find a postbox today!`
      );
    })
  );
}

/**
 * Notifies friends in `uid`'s list whom this claim just overtook.
 *
 * `prevDailyPoints` is the user's total BEFORE this claim session; `newDailyPoints`
 * is the total AFTER. The notification fires only for friends whose score sits in
 * the `(prevDailyPoints, newDailyPoints]` range — those the user just crossed.
 */
export async function notifyFriendOvertake(
  uid: string,
  displayName: string,
  prevDailyPoints: number,
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
      if (!shouldNotifyOvertake(fdata, prevDailyPoints, newDailyPoints)) return;
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
  // Transaction prevents a race when the same user signs in on two devices
  // concurrently — a plain read-modify-write would drop whichever write
  // committed first. updateFcmTokens returns the same reference when the token
  // already exists, so we skip the write in that case to avoid a needless
  // transaction commit.
  await database.runTransaction(async (tx) => {
    const tokenDoc = await tx.get(tokenRef);
    const existing: string[] = (tokenDoc.data()?.tokens as string[] | undefined) ?? [];
    const updated = updateFcmTokens(existing, token);
    if (updated === existing) return;
    tx.set(tokenRef, { tokens: updated }, { merge: true });
  });
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
