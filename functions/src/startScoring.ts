import "./adminInit";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import { getPoints } from "./_getPoints";
import { getTodayLondon } from "./_dateUtils";
import { lookupPostboxes, getLatLng } from "./_lookupPostboxes";
import { updateUserLeaderboards, mergeLifetimeEntries, LifetimeLeaderboardEntry, getWeekStart, getMonthStart } from "./_leaderboardUtils";
import { computeNewStreak } from "./_streakUtils";
import { notifyFriendsFirstClaim, notifyFriendOvertake } from "./_notifications";
import { checkTravelSpeed } from "./_travelSpeed";

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

  // Anti-spoof: reject claims whose implied travel speed from the user's
  // previous claim exceeds a liberal physical limit. Fail-open when the
  // previous claim's location can't be resolved (e.g. legacy claims where
  // neither userLat/userLng nor the referenced postbox geopoint are
  // available).
  await enforceTravelSpeedLimit(userid, lat, lng);

  // Hoist date computation so all return paths include dailyDate for consistency.
  const todayLondon = getTodayLondon();

  const results = await lookupPostboxes(lat, lng, CLAIM_RADIUS_METERS);

  if (results.counts.total === 0) {
    return { found: false, claimed: 0, points: 0, allClaimedToday: false, dailyDate: todayLondon };
  }

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
      .map(ref => ref.replace(/^\/postbox\//, ""))
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
          // Persist the user's GPS at claim time so the next claim's travel-speed
          // check uses the user's own position, not the postbox coordinates.
          userLat: lat,
          userLng: lng,
        };
        if (postbox.monarch !== undefined) claimData.monarch = postbox.monarch;
        tx.set(claimRef, claimData);
        // Keep dailyClaim on the postbox doc for display purposes (shows
        // "someone found this today" in future UI); does not gate claiming.
        tx.set(postboxRef, { dailyClaim: { date: todayLondon, by: userid } }, { merge: true });
        return { key, pts };
      });
    })
  );

  const rejectedCount = claimSettled.filter(r => r.status === "rejected").length;
  for (const result of claimSettled) {
    if (result.status === "rejected") {
      console.error("claim transaction failed:", result.reason);
    }
  }

  const successfulClaims = claimSettled
    .filter((r): r is PromiseFulfilledResult<{ key: string; pts: number }> =>
      r.status === "fulfilled" &&
      r.value !== null &&
      typeof r.value === "object" &&
      "key" in r.value
    )
    .map((r) => r.value);

  const earnedPoints = successfulClaims.map((c) => c.pts);

  // If no points were earned but at least one transaction was rejected (as
  // opposed to being skipped because already claimed today), surface an error
  // so the client shows a retry prompt rather than "Already claimed today".
  if (earnedPoints.length === 0 && rejectedCount > 0) {
    throw new functions.https.HttpsError("internal", "Claim failed due to a server error. Please try again.");
  }

  if (earnedPoints.length > 0) {
    // Compute yesterday once; used by the streak transaction below.
    const yesterdayDate = new Date(todayLondon + "T00:00:00Z");
    yesterdayDate.setUTCDate(yesterdayDate.getUTCDate() - 1);
    const yesterday = yesterdayDate.toISOString().slice(0, 10);
    const userRef = database.collection("users").doc(userid);

    // Fetch displayName and update streak in parallel. The streak transaction
    // only writes lastClaimDate/streak — never displayName — so both
    // operations read independent fields of the same document safely.
    const [userDoc] = await Promise.all([
      userRef.get(),
      // Update daily-claim streak. Runs server-side (Admin SDK) because
      // Firestore rules restrict client writes on users/{uid} to the friends
      // array only, to prevent profanity-filter bypass on displayName.
      database.runTransaction(async (tx) => {
        const snap = await tx.get(userRef);
        const d = snap.data() ?? {};
        const lastClaimDate = d.lastClaimDate as string | undefined;
        const currentStreak = (d.streak as number | undefined) ?? 0;
        const newStreak = computeNewStreak(lastClaimDate, currentStreak, todayLondon, yesterday);
        if (newStreak === null) return; // already updated today
        tx.set(userRef, { lastClaimDate: todayLondon, streak: newStreak }, { merge: true });
      }).catch((streakErr) => {
        console.error("streak update failed (non-fatal):", streakErr);
      }),
    ]);
    const displayName =
      (userDoc.data()?.displayName as string | undefined) ||
      `Player_${userid.slice(0, 6)}`;
    const userAvatar = userDoc.data()?.avatar as Record<string, number> | undefined;

    // Run the period leaderboard update and the uniqueness checks in parallel.
    // updateUserLeaderboards uses Promise.allSettled internally and never
    // throws; uniqueness checks use allSettled so individual read failures
    // only affect that postbox's unique count without aborting the rest.
    const [periodSums, uniqueCheckResults] = await Promise.all([
      updateUserLeaderboards(userid, displayName, todayLondon, database, userAvatar),
      Promise.allSettled(
        // For each postbox claimed this session, check whether the user has any
        // prior claim on a different day. Empty result → first-ever claim for
        // that postbox → increment the unique counter by 1.
        successfulClaims.map(({ key }) =>
          database.collection("claims")
            .where("userid", "==", userid)
            .where("postboxes", "==", `/postbox/${key}`)
            .where("dailyDate", "<", todayLondon)
            .limit(1)
            .get()
            .then((snap) => snap.empty ? 1 : 0)
        )
      ),
    ]);

    // ── Lifetime leaderboard update ─────────────────────────────────────────
    // Use a single transaction to atomically increment the user's lifetime
    // counters and update the leaderboard. Doing this as two separate
    // operations (increment + get + leaderboard write) has a race: a
    // concurrent claim from another device could increment the counter
    // between our write and our read, causing the leaderboard to reflect
    // the other session's total instead of ours.
    const lifetimePointsIncrement = earnedPoints.reduce((s, p) => s + p, 0);
    let capturedNewDailyPoints: number | null = null;
    let capturedPrevDailyPoints: number | null = null;

    // Period sums returned by updateUserLeaderboards are the authoritative
    // totals — they were summed from the claims collection after this
    // session's claim transactions committed. We SET those values on
    // users/{uid} inside the lifetime tx instead of FieldValue.increment so
    // the per-user period counters can never drift away from the claims
    // collection (e.g. when a new period marker is introduced mid-period).
    const currentWeekStart = getWeekStart(todayLondon);
    const currentMonthStart = getMonthStart(todayLondon);

    try {
      for (const r of uniqueCheckResults) {
        if (r.status === "rejected") {
          console.error("uniqueChecks read failed (non-fatal):", r.reason);
        }
      }
      const uniqueIncrement = uniqueCheckResults
        .filter((r) => r.status === "fulfilled")
        .reduce((a, r) => a + (r as PromiseFulfilledResult<number>).value, 0);

      const lifetimeRef = database.collection("leaderboards").doc("lifetime");

      await database.runTransaction(async (tx) => {
        const [userSnap, lifetimeSnap] = await Promise.all([
          tx.get(userRef),
          tx.get(lifetimeRef),
        ]);
        const d = userSnap.data() ?? {};
        const newUnique = ((d.uniquePostboxesClaimed as number | undefined) ?? 0) + uniqueIncrement;
        const newLifetimePoints = ((d.lifetimePoints as number | undefined) ?? 0) + lifetimePointsIncrement;
        const newMaxDailyPoints = Math.max(
          (d.maxDailyPoints as number | undefined) ?? 0,
          periodSums.dailyPoints
        );
        // Read displayName inside the transaction so a concurrent
        // updateDisplayName that commits between this function's earlier
        // userRef.get() and the tx commit doesn't get overwritten with the
        // stale pre-fetched name when we write the lifetime entry below.
        const freshDisplayName =
          (d.displayName as string | undefined) || displayName;
        const freshAvatar =
          (d.avatar as Record<string, number> | undefined) ?? userAvatar;

        tx.set(
          userRef,
          {
            uniquePostboxesClaimed: newUnique,
            lifetimePoints: newLifetimePoints,
            dailyPoints: periodSums.dailyPoints,
            dailyDate: todayLondon,
            weeklyPoints: periodSums.weeklyPoints,
            weekStart: currentWeekStart,
            monthlyPoints: periodSums.monthlyPoints,
            monthStart: currentMonthStart,
            maxDailyPoints: newMaxDailyPoints,
          },
          { merge: true }
        );

        const existingEntries = (lifetimeSnap.data()?.entries ?? []) as LifetimeLeaderboardEntry[];
        const updatedEntries = mergeLifetimeEntries(existingEntries, userid, freshDisplayName, newUnique, newLifetimePoints, 100, freshAvatar);
        tx.set(lifetimeRef, { periodKey: "lifetime", entries: updatedEntries }, { merge: false });
      });

      // The authoritative daily sum already includes this session's claims,
      // so the pre-session total is the sum minus what we earned this call.
      capturedNewDailyPoints = periodSums.dailyPoints;
      capturedPrevDailyPoints = periodSums.dailyPoints - lifetimePointsIncrement;
    } catch (lifetimeErr) {
      console.error("lifetime leaderboard update failed (non-fatal):", lifetimeErr);
    }

    // Fire-and-forget social notifications — not awaited so claim latency is
    // unaffected. userClaimsSnap.docs.length === 0 means this is the user's
    // first claim of the day.
    void (async () => {
      try {
        const isFirstClaimToday = userClaimsSnap.docs.length === 0;
        // Prefer values captured inside the lifetime transaction (fresh).
        // Fall back to the pre-transaction estimate only if the transaction
        // failed — in that case the leaderboard wasn't updated either.
        // The pre-tx fallback must account for staleness: dailyPoints is
        // never reset server-side, so a value from a previous day would
        // inflate prevDailyPoints and suppress a legitimate overtake
        // notification (shouldNotifyOvertake bails when prev > friendDaily).
        const storedDailyDate = userDoc.data()?.dailyDate as string | undefined;
        const fallbackPrev = storedDailyDate === todayLondon
          ? ((userDoc.data()?.dailyPoints as number | undefined) ?? 0)
          : 0;
        const prevDailyPoints = capturedPrevDailyPoints ?? fallbackPrev;
        const newDailyPoints = capturedNewDailyPoints ??
          prevDailyPoints + lifetimePointsIncrement;
        await Promise.allSettled([
          ...(isFirstClaimToday
            ? [notifyFriendsFirstClaim(userid, displayName)]
            : []),
          notifyFriendOvertake(userid, displayName, prevDailyPoints, newDailyPoints),
        ]);
      } catch (notifErr) {
        console.error("notification error (non-fatal):", notifErr);
      }
    })();
  }

  return {
    found: true,
    claimed: earnedPoints.length,
    points: earnedPoints.reduce((s, p) => s + p, 0),
    allClaimedToday: earnedPoints.length === 0,
    dailyDate: todayLondon,
  };
});

/** Resolve the user's most recent claim location and reject the request if
 *  the implied travel speed exceeds MAX_METRES_PER_MIN. Location resolution
 *  order: (1) userLat/userLng stored on the claim doc (written going
 *  forward); (2) geopoint of the referenced postbox (legacy fallback). If
 *  neither yields a coordinate pair, the check is skipped. */
async function enforceTravelSpeedLimit(userid: string, currentLat: number, currentLng: number): Promise<void> {
  const lastSnap = await database.collection("claims")
    .where("userid", "==", userid)
    .orderBy("timestamp", "desc")
    .limit(1)
    .get();
  if (lastSnap.empty) return;
  const last = lastSnap.docs[0].data();
  const tsMs = (last.timestamp as admin.firestore.Timestamp | undefined)?.toMillis?.();
  if (!tsMs) return;

  let lastLat = typeof last.userLat === "number" ? (last.userLat as number) : undefined;
  let lastLng = typeof last.userLng === "number" ? (last.userLng as number) : undefined;

  if (lastLat === undefined || lastLng === undefined) {
    const postboxPath = last.postboxes as string | undefined;
    const postboxKey = typeof postboxPath === "string"
      ? postboxPath.replace(/^\/postbox\//, "")
      : undefined;
    if (!postboxKey) return;
    const postboxSnap = await database.collection("postbox").doc(postboxKey).get();
    if (!postboxSnap.exists) return;
    const geo = getLatLng((postboxSnap.data() ?? {}).geopoint);
    if (!geo) return;
    lastLat = geo.lat;
    lastLng = geo.lng;
  }

  const check = checkTravelSpeed({
    lastLat,
    lastLng,
    lastTimestampMs: tsMs,
    currentLat,
    currentLng,
    nowMs: Date.now(),
  });
  if (!check.ok) {
    console.warn(`travel-speed check rejected uid=${userid} speed=${check.speedMPerMin.toFixed(1)} m/min distance=${check.distanceMetres}m elapsedMin=${check.elapsedMinutes.toFixed(3)}`);
    throw new functions.https.HttpsError(
      "failed-precondition",
      "You're travelling too fast — slow down before your next postbox claim."
    );
  }
}
