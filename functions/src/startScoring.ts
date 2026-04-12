import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import { getPoints } from "./_getPoints";
import { getTodayLondon } from "./_dateUtils";
import { lookupPostboxes } from "./_lookupPostboxes";
import { updateUserLeaderboards } from "./_leaderboardUtils";
import { computeNewStreak } from "./_streakUtils";

const database = admin.firestore();

/** Radius (metres) within which a user must stand to claim a postbox.
 *  Must match AppPreferences.claimRadiusMeters in lib/app_preferences.dart. */
const CLAIM_RADIUS_METERS = 30;

interface StartScoringCallData {
  lat?: number;
  lng?: number;
}

export const startScoring = functions.https.onCall(async (request) => {
  const userid = request.auth?.uid;
  if (!userid) {
    throw new functions.https.HttpsError("unauthenticated", "Must be signed in to claim a postbox");
  }

  const { lat, lng } = (request.data as StartScoringCallData) ?? {};
  if (lat === undefined || lat === null || lng === undefined || lng === null) {
    throw new functions.https.HttpsError("invalid-argument", "lat and lng are required");
  }
  if (!Number.isFinite(lat) || lat < -90 || lat > 90) {
    throw new functions.https.HttpsError("invalid-argument", "lat must be a finite number between -90 and 90");
  }
  if (!Number.isFinite(lng) || lng < -180 || lng > 180) {
    throw new functions.https.HttpsError("invalid-argument", "lng must be a finite number between -180 and 180");
  }

  const results = await lookupPostboxes(lat, lng, CLAIM_RADIUS_METERS);

  if (results.counts.total === 0) {
    return { found: false, claimed: 0, points: 0, allClaimedToday: false };
  }

  // Hoist date computation so all return paths include dailyDate for consistency.
  const todayLondon = getTodayLondon();

  // Pre-fetch this user's today claims so we can check per-user claim status
  // without a postbox-document read inside every transaction.  One query covers
  // all postboxes in range; we extract the postbox keys from the stored path.
  const userClaimsSnap = await database.collection('claims')
    .where('userid', '==', userid)
    .where('dailyDate', '==', todayLondon)
    .get();
  const userClaimedKeys = new Set(
    userClaimsSnap.docs
      .map(d => d.data().postboxes as string | undefined)
      .filter((ref): ref is string => typeof ref === "string")
      .map(ref => ref.replace("/postbox/", ""))
  );

  // Fast-path: if every postbox in range was already claimed today by THIS USER,
  // skip all transactions.  Uses per-user data so other players' claims don't
  // block the current user.
  const userClaimedInRange = Object.keys(results.postboxes)
    .filter(k => userClaimedKeys.has(k)).length;
  if (userClaimedInRange === results.counts.total) {
    return { found: true, claimed: 0, points: 0, allClaimedToday: true, dailyDate: todayLondon };
  }

  // Use allSettled so a single transient transaction failure does not discard
  // points from postboxes whose transactions already committed successfully.
  const claimSettled = await Promise.allSettled(
    Object.entries(results.postboxes).map(([key, postbox]) => {
      // Per-user skip: if this user has already claimed this postbox today
      // (from the pre-fetch), skip without a transaction.  Other users' claims
      // do NOT block the current user.
      if (userClaimedKeys.has(key)) return Promise.resolve(null);

      const postboxRef = database.collection('postbox').doc(key);
      // Deterministic claim ID: one document per (user, postbox, date) triple.
      // The transaction reads this doc to confirm the user hasn't claimed since
      // the pre-fetch, then creates it atomically — preventing double-claims from
      // concurrent requests.
      const claimRef = database.collection('claims').doc(`${userid}_${key}_${todayLondon}`);
      const pts = postbox.monarch !== undefined ? getPoints(postbox.monarch) : 2;

      return database.runTransaction(async (tx) => {
        const claimSnap = await tx.get(claimRef);
        if (claimSnap.exists) return null; // concurrent request already claimed

        const claimData: Record<string, unknown> = {
          userid,
          timestamp: admin.firestore.Timestamp.now(),
          validated: false,
          postboxes: `/postbox/${key}`,
          points: pts,
          dailyDate: todayLondon,
        };
        if (postbox.monarch !== undefined) claimData.monarch = postbox.monarch;
        tx.set(claimRef, claimData);
        // Keep dailyClaim on the postbox doc for display purposes (shows
        // "someone found this today" in future UI); does not gate claiming.
        tx.set(postboxRef, { dailyClaim: { date: todayLondon, by: userid } }, { merge: true });
        return pts;
      });
    })
  );

  const rejectedCount = claimSettled.filter(r => r.status === "rejected").length;
  for (const result of claimSettled) {
    if (result.status === "rejected") {
      console.error("claim transaction failed:", result.reason);
    }
  }

  const earnedPoints = claimSettled
    .filter((r): r is PromiseFulfilledResult<number> => r.status === "fulfilled" && typeof r.value === "number")
    .map((r) => r.value);

  // If no points were earned but at least one transaction was rejected (as
  // opposed to being skipped because already claimed today), surface an error
  // so the client shows a retry prompt rather than "Already claimed today".
  if (earnedPoints.length === 0 && rejectedCount > 0) {
    throw new functions.https.HttpsError("internal", "Claim failed due to a server error. Please try again.");
  }

  if (earnedPoints.length > 0) {
    const userDoc = await database.collection('users').doc(userid).get();
    const displayName =
      (userDoc.data()?.displayName as string | undefined) ||
      `Player_${userid.slice(0, 6)}`;

    // Update daily-claim streak. Runs server-side (Admin SDK) because
    // Firestore rules restrict client writes on users/{uid} to the friends
    // array only, to prevent profanity-filter bypass on displayName.
    const yesterdayDate = new Date(todayLondon + "T00:00:00Z");
    yesterdayDate.setUTCDate(yesterdayDate.getUTCDate() - 1);
    const yesterday = yesterdayDate.toISOString().slice(0, 10);
    const userRef = database.collection("users").doc(userid);
    try {
      await database.runTransaction(async (tx) => {
        const snap = await tx.get(userRef);
        const d = snap.data() ?? {};
        const lastClaimDate = d.lastClaimDate as string | undefined;
        const currentStreak = (d.streak as number | undefined) ?? 0;
        const newStreak = computeNewStreak(lastClaimDate, currentStreak, todayLondon, yesterday);
        if (newStreak === null) return; // already updated today
        tx.set(userRef, { lastClaimDate: todayLondon, streak: newStreak }, { merge: true });
      });
    } catch (streakErr) {
      console.error("streak update failed (non-fatal):", streakErr);
    }

    // updateUserLeaderboards uses Promise.allSettled internally and never
    // throws; individual period failures are logged inside the function.
    await updateUserLeaderboards(userid, displayName, todayLondon, database);
  }

  return {
    found: true,
    claimed: earnedPoints.length,
    points: earnedPoints.reduce((s, p) => s + p, 0),
    allClaimedToday: earnedPoints.length === 0,
    dailyDate: todayLondon,
  };
});
