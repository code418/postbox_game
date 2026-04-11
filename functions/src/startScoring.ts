import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import { getPoints } from "./_getPoints";
import { getTodayLondon } from "./_dateUtils";
import { lookupPostboxes } from "./_lookupPostboxes";
import { updateUserLeaderboards } from "./_leaderboardUtils";

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

  // Fast-path: if every postbox in range was already claimed today, skip transactions.
  if (results.counts.claimedToday === results.counts.total) {
    return { found: true, claimed: 0, points: 0, allClaimedToday: true };
  }

  const todayLondon = getTodayLondon();

  // Use allSettled so a single transient transaction failure does not discard
  // points from postboxes whose transactions already committed successfully.
  const claimSettled = await Promise.allSettled(
    Object.entries(results.postboxes).map(([key, postbox]) => {
      // Use our own todayLondon (not the derived claimedToday flag from
      // lookupPostboxes) to guard against a rare midnight rollover between
      // the two getTodayLondon() calls.
      if (postbox.dailyClaim?.date === todayLondon) return Promise.resolve(null);

      const postboxRef = database.collection('postbox').doc(key);
      const claimRef   = database.collection('claims').doc();
      const pts = postbox.monarch !== undefined ? getPoints(postbox.monarch) : 2;

      return database.runTransaction(async (tx) => {
        const snap = await tx.get(postboxRef);
        if (snap.data()?.dailyClaim?.date === todayLondon) return null;

        tx.set(postboxRef, { dailyClaim: { date: todayLondon, by: userid } }, { merge: true });
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
    // Retry leaderboard update once on transient Firestore errors.
    try {
      await updateUserLeaderboards(userid, displayName, todayLondon, database);
    } catch (err) {
      try {
        await updateUserLeaderboards(userid, displayName, todayLondon, database);
      } catch (retryErr) {
        console.error("updateUserLeaderboards failed after retry:", retryErr);
      }
    }
  }

  return {
    found: true,
    claimed: earnedPoints.length,
    points: earnedPoints.reduce((s, p) => s + p, 0),
    allClaimedToday: earnedPoints.length === 0,
    dailyDate: todayLondon,
  };
});
