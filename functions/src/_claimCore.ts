// The claim scoring core (ROADMAP v1.5 B1) — the single write path shared by
// the live `startScoring` callable and the offline `flushOfflineClaims`
// callable. Lifted verbatim out of startScoring.ts in the spirit of
// _routePlanner.ts: one source of truth for the scoring maths and the
// leaderboard/streak bookkeeping.
//
// The callable keeps: request validation, App Check, the attempts idempotency
// wrapper, and the cross-language-pinned CLAIM_RADIUS_METERS constant.

import "./adminInit";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import { getGameConfig, resolvePointsForMonarch } from "./_config";
import { getTodayLondon } from "./_dateUtils";
import { lookupPostboxes, getLatLng } from "./_lookupPostboxes";
import { updateUserLeaderboards, mergeLifetimeEntries, LifetimeLeaderboardEntry, getWeekStart, getMonthStart, countySlug } from "./_leaderboardUtils";
import { computeNewStreak, streakFromClaimDays } from "./_streakUtils";
import { notifyFriendsFirstClaim, notifyFriendOvertake } from "./_notifications";
import { checkNeighbourSpeeds, NeighbourPoint } from "./_travelSpeed";
import { coordKey } from "./_abuseSignals";

const database = admin.firestore();

/**
 * TEMPORARY (2026-07-24, requested by product): the hard travel-speed reject is
 * disabled so we can observe the feature's real-world behaviour before deciding
 * whether to re-enable enforcement. While disabled the speed is STILL computed,
 * logged (as a "would-reject" warning), and returned to the shadow-mode anomaly
 * detector (_abuseSignals), so the feature's effectiveness can be reviewed from
 * the logs / flag docs without blocking any legitimate claims.
 *
 * To re-enable: set the TRAVEL_SPEED_ENFORCEMENT env var to "on" (no redeploy of
 * this constant needed), or flip the default below back to "on".
 */
export function travelSpeedEnforcementEnabled(
  env: Record<string, string | undefined> = process.env,
): boolean {
  return (env.TRAVEL_SPEED_ENFORCEMENT ?? "off").toLowerCase() === "on";
}

/** Resolved once at module load, so a change to the env var takes effect on the
 *  next cold start (which is how Cloud Functions env vars work anyway). */
export const TRAVEL_SPEED_ENFORCEMENT_ENABLED = travelSpeedEnforcementEnabled();

/** The patch merged onto a `postbox` doc when it's claimed: only the London
 *  date it was last claimed (a "someone found this today" display hint).
 *
 *  The claimant's uid is DELIBERATELY not stored. `postbox/{id}` carries the
 *  exact `geopoint`, and `users/{uid}.displayName` is world-readable — so a
 *  uid here would let a scraper reconstruct "displayName X was at <exact
 *  location> on <date>" for every claimer. `dailyClaim.by` is never read
 *  anywhere (the server reads only `dailyClaim.date` in _lookupPostboxes), so
 *  dropping it removes location PII with zero functional impact. Exported so a
 *  unit test can pin that no uid is ever reintroduced here. */
export function dailyClaimPatch(date: string): { dailyClaim: { date: string } } {
  return { dailyClaim: { date } };
}

/** Queue metadata for a claim adjudicated by the offline flush path. Derived
 *  SERVER-SIDE from which handler ran — never from client payload, or
 *  `offline` becomes a self-declared exemption from the abuse signals. */
export interface OfflineClaimMeta {
  /** How long the capture sat in the client outbox before flushing. */
  queuedForMs: number;
  /** Number of captures in the flush batch this claim arrived with. */
  batchSize: number;
  /** Time span covered by the batch's capture times. */
  batchSpanMs: number;
  /** Client wall-clock at FLUSH time (clock-skew signal — the capture-time
   *  clientTsMs is meaningless for an offline claim's out-of-window check). */
  flushClientTsMs?: number;
  /** Coefficient of variation of implied speeds across the batch's capture
   *  legs (computed at flush time — the only place the whole batch is
   *  visible). Near-zero = synthesised trace (constant_batch_speed signal). */
  batchSpeedCv?: number;
}

/** Optional inputs to [scoreClaimAt] beyond the position. */
export interface ScoreClaimOptions {
  /** Client wall-clock at claim time (shadow-mode out-of-window signal). */
  clientTsMs?: number;
  /** Per-install random id (shadow-mode repeated-device signal). */
  deviceIdHash?: string;
  /** When the user was physically at the position (ms since epoch). Defaults
   *  to now (live claim). The flush path passes the verified capture time. */
  eventTimeMs?: number;
  /** The London day the claim belongs to (YYYY-MM-DD). Defaults to the real
   *  today. The flush path passes the capture day so the claim doc, dedup id
   *  and claimedToday comparisons all use the day the user was there.
   *  NEVER passed to updateUserLeaderboards — see the leaderboard note below. */
  claimDate?: string;
  /** Present iff this claim is being adjudicated by flushOfflineClaims. */
  offline?: OfflineClaimMeta;
}

/** Everything needed to construct one claim document. Pure — exported for
 *  unit tests pinning the eventTime/offline field semantics. */
export interface BuildClaimDataInput {
  userid: string;
  postboxKey: string;
  points: number;
  claimDate: string;
  lat: number;
  lng: number;
  /** Immutable server-write time — the audit trail; abuse.ts reads it. */
  timestamp: admin.firestore.Timestamp;
  /** When the user was physically there. Equal to [timestamp] for live
   *  claims; the verified capture time for flushed offline claims. The
   *  travel-speed neighbour queries order by THIS field. */
  eventTime: admin.firestore.Timestamp;
  monarch?: string;
  clientTsMs?: number;
  travelSpeed?: number;
  deviceIdHash?: string;
  offline?: OfflineClaimMeta;
}

export function buildClaimData(inp: BuildClaimDataInput): Record<string, unknown> {
  const d: Record<string, unknown> = {
    userid: inp.userid,
    timestamp: inp.timestamp,
    eventTime: inp.eventTime,
    validated: false,
    postboxes: `/postbox/${inp.postboxKey}`,
    points: inp.points,
    dailyDate: inp.claimDate,
    // Persist the user's GPS at claim time so the next claim's travel-speed
    // check uses the user's own position, not the postbox coordinates.
    userLat: inp.lat,
    userLng: inp.lng,
    // Rounded coordinate key for the shadow-mode clustering signal — lets
    // the onClaimCreated trigger count same-spot claims with an equality
    // query instead of scanning raw doubles.
    coordKey6: coordKey(inp.lat, inp.lng),
  };
  // Optional fields are omitted (never undefined) so Firestore writes stay clean.
  if (inp.monarch !== undefined) d.monarch = inp.monarch;
  if (inp.clientTsMs !== undefined) d.clientTsMs = inp.clientTsMs;
  if (inp.travelSpeed !== undefined) d.travelSpeed = inp.travelSpeed;
  if (inp.deviceIdHash !== undefined) d.deviceIdHash = inp.deviceIdHash;
  if (inp.offline) {
    d.offline = true;
    d.queuedForMs = inp.offline.queuedForMs;
    d.batchSize = inp.offline.batchSize;
    d.batchSpanMs = inp.offline.batchSpanMs;
    if (inp.offline.flushClientTsMs !== undefined) {
      d.flushClientTsMs = inp.offline.flushClientTsMs;
    }
    if (inp.offline.batchSpeedCv !== undefined) {
      d.batchSpeedCv = inp.offline.batchSpeedCv;
    }
  }
  return d;
}

/**
 * Score a claim for [userid] standing at ([lat], [lng]) now: claims every
 * unclaimed in-range postbox, updates the user's streak and every leaderboard,
 * and fires the social notifications. Returns the callable response object.
 */
export async function scoreClaimAt(
  userid: string,
  lat: number,
  lng: number,
  opts: ScoreClaimOptions = {},
): Promise<Record<string, unknown>> {
  const { clientTsMs, deviceIdHash, offline } = opts;
  const nowMs = Date.now();
  const eventTimeMs = opts.eventTimeMs ?? nowMs;

  // Hoist date computation so all return paths include dailyDate for
  // consistency. todayLondon is ALWAYS the real today (leaderboards depend on
  // it — see the landmine note below); claimDate is the day the user was
  // physically at the box, which differs only on the offline flush path.
  const todayLondon = getTodayLondon();
  const claimDate = opts.claimDate ?? todayLondon;

  // Anti-spoof: reject claims implausibly fast against BOTH eventTime
  // neighbours (the claim before and after the claimed moment). Fail-open per
  // side when a neighbour's location can't be resolved. Returns the implied
  // speed vs the previous claim for the shadow-mode anomaly detector.
  const travelSpeed = await enforceNeighbourSpeedLimit(userid, lat, lng, eventTimeMs);

  // Fetch the Remote-Config-driven game balance once (5-min cached in _config).
  // claim radius + per-monarch points both resolve from here, falling back to
  // the hard-coded constants when Remote Config is absent/invalid.
  const gameConfig = await getGameConfig();

  const results = await lookupPostboxes(lat, lng, gameConfig.claimRadiusMeters, claimDate);

  if (results.counts.total === 0) {
    return { found: false, claimed: 0, points: 0, allClaimedToday: false, dailyDate: claimDate };
  }

  // Pre-fetch this user's claims for the claim day so we can check per-user
  // claim status without a postbox-document read inside every transaction.
  // One query covers all postboxes in range; we extract the postbox keys from
  // the stored path.
  const userClaimsSnap = await database.collection('claims')
    .where('userid', '==', userid)
    .where('dailyDate', '==', claimDate)
    .get();
  const userClaimedKeys = new Set(
    userClaimsSnap.docs
      .map(d => d.data().postboxes as string | undefined)
      .filter((ref): ref is string => typeof ref === "string")
      .map(ref => ref.replace(/^\/postbox\//, ""))
  );

  // Fast-path: if every postbox in range was already claimed on the claim day
  // by THIS USER, skip all transactions.  Uses per-user data so other players'
  // claims don't block the current user.
  const userClaimedInRange = Object.keys(results.postboxes)
    .filter(k => userClaimedKeys.has(k)).length;
  if (userClaimedInRange === results.counts.total) {
    return { found: true, claimed: 0, points: 0, allClaimedToday: true, dailyDate: claimDate };
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
      const claimRef = database.collection('claims').doc(`${userid}_${key}_${claimDate}`);
      const pts = resolvePointsForMonarch(gameConfig, postbox.monarch);

      return database.runTransaction(async (tx) => {
        const claimSnap = await tx.get(claimRef);
        if (claimSnap.exists) return null; // concurrent request already claimed

        const writeTs = admin.firestore.Timestamp.now();
        tx.set(claimRef, buildClaimData({
          userid,
          postboxKey: key,
          points: pts,
          claimDate,
          lat,
          lng,
          timestamp: writeTs,
          // Live claims: the claimed moment IS the write moment. Flush: the
          // verified capture time.
          eventTime: opts.eventTimeMs !== undefined
            ? admin.firestore.Timestamp.fromMillis(opts.eventTimeMs)
            : writeTs,
          monarch: postbox.monarch,
          clientTsMs,
          travelSpeed,
          deviceIdHash,
          offline,
        }));
        // Keep dailyClaim on the postbox doc for display purposes (shows
        // "someone found this today" in future UI); does not gate claiming.
        // The claimant's uid is deliberately NOT written — see dailyClaimPatch.
        // Backdated claims write their capture day, which correctly does NOT
        // read as "found today" in _lookupPostboxes.
        tx.set(postboxRef, dailyClaimPatch(claimDate), { merge: true });
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
    const isBackdated = claimDate !== todayLondon;

    // Fetch displayName and update streak in parallel. The streak transaction
    // only writes lastClaimDate/streak — never displayName — so both
    // operations read independent fields of the same document safely.
    const [userDoc] = await Promise.all([
      userRef.get(),
      // Update daily-claim streak. Runs server-side (Admin SDK) because
      // Firestore rules restrict client writes on users/{uid} to the friends
      // array only, to prevent profanity-filter bypass on displayName.
      //
      // Live claims keep the cheap incremental computeNewStreak. A BACKDATED
      // claim (offline flush) instead recomputes from the user's distinct
      // claim days — computeNewStreak is forward-only and a Tuesday-dated
      // flush landing after Wednesday's live claim would otherwise never
      // repair the chain. This is what turns a late flush into a SAVED streak.
      isBackdated
        ? recomputeStreakFromClaims(userid, todayLondon).catch((streakErr) => {
            console.error("streak recompute failed (non-fatal):", streakErr);
          })
        : database.runTransaction(async (tx) => {
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

    // Run the period leaderboard update and the uniqueness checks in parallel.
    // updateUserLeaderboards uses Promise.allSettled internally and never
    // throws; uniqueness checks use allSettled so individual read failures
    // only affect that postbox's unique count without aborting the rest.
    //
    // ⚠️ updateUserLeaderboards must ALWAYS receive the REAL today, never a
    // backdated claimDate: a stale day makes its periodKey mismatch, which
    // empties `existing` and rewrites the daily board with {merge:false} —
    // wiping every player's daily leaderboard under yesterday's key. Its
    // weekly/monthly range queries pick up a backdated claim automatically;
    // a *closed* daily board is the only thing not credited, and no UI can
    // display one. Pinned by the "backdated today must not clobber the daily
    // board" test.
    const [periodSums, uniqueCheckResults] = await Promise.all([
      updateUserLeaderboards(userid, displayName, todayLondon, database),
      Promise.allSettled(
        // For each postbox claimed this session, count the user's claims on
        // that box — the claim just written included. Exactly 1 → first-ever
        // claim → increment the unique counter. (The previous
        // `dailyDate < today` probe missed LATER same-box claims when
        // adjudicating a backdated capture and double-counted uniques.)
        successfulClaims.map(({ key }) =>
          database.collection("claims")
            .where("userid", "==", userid)
            .where("postboxes", "==", `/postbox/${key}`)
            .count()
            .get()
            .then((agg) => (agg.data().count === 1 ? 1 : 0))
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

        // Streak resilience: the parallel streak tx is fire-and-forget and
        // can silently fail (its error is just logged). Detect the post-tx
        // state here and recover. If lastClaimDate is already today, the
        // streak tx committed and we leave it alone. Otherwise, compute the
        // streak update inline and include it in this tx's write so a
        // dropped streak update doesn't permanently break the user's chain.
        // LIVE PATH ONLY: this fallback assumes the claim happened today, so
        // it would corrupt the recomputed streak of a backdated flush claim.
        const lastClaimDate = d.lastClaimDate as string | undefined;
        const currentStreak = (d.streak as number | undefined) ?? 0;
        const fallbackStreak = (isBackdated || lastClaimDate === todayLondon)
          ? null
          : computeNewStreak(lastClaimDate, currentStreak, todayLondon, yesterday);

        const userUpdate: Record<string, unknown> = {
          uniquePostboxesClaimed: newUnique,
          lifetimePoints: newLifetimePoints,
          dailyPoints: periodSums.dailyPoints,
          dailyDate: todayLondon,
          weeklyPoints: periodSums.weeklyPoints,
          weekStart: currentWeekStart,
          monthlyPoints: periodSums.monthlyPoints,
          monthStart: currentMonthStart,
          maxDailyPoints: newMaxDailyPoints,
        };
        if (fallbackStreak !== null) {
          userUpdate.lastClaimDate = todayLondon;
          userUpdate.streak = fallbackStreak;
        }
        tx.set(userRef, userUpdate, { merge: true });

        const existingEntries = (lifetimeSnap.data()?.entries ?? []) as LifetimeLeaderboardEntry[];
        const updatedEntries = mergeLifetimeEntries(existingEntries, userid, freshDisplayName, newUnique, newLifetimePoints);
        tx.set(lifetimeRef, { periodKey: "lifetime", entries: updatedEntries }, { merge: false });
      });

      // The authoritative daily sum already includes this session's claims,
      // so the pre-session total is the sum minus what we earned this call.
      capturedNewDailyPoints = periodSums.dailyPoints;
      capturedPrevDailyPoints = periodSums.dailyPoints - lifetimePointsIncrement;
    } catch (lifetimeErr) {
      console.error("lifetime leaderboard update failed (non-fatal):", lifetimeErr);
    }

    // ── Per-county lifetime updates ─────────────────────────────────────────
    // Group this session's successful claims by the postbox's county, summing
    // points and counting unique-postbox increments per county. Each county
    // gets one transaction that updates users/{uid}/countyStats/{slug} and
    // leaderboards/lifetime_by_county/{slug} atomically — same shape as the
    // global lifetime update above.
    //
    // Postboxes without a `county` field (e.g. NI postboxes outside the GB
    // boundary dataset, or pre-backfill imports) are silently skipped so this
    // never blocks a claim.
    const countyAgg = new Map<string, { name: string; points: number; unique: number }>();
    for (let i = 0; i < successfulClaims.length; i++) {
      const { key, pts } = successfulClaims[i];
      const county = (results.postboxes[key]?.county as string | undefined);
      if (!county) continue;
      const slug = countySlug(county);
      if (!slug) continue;
      const uniqueResult = uniqueCheckResults[i];
      const uniqueDelta = uniqueResult?.status === "fulfilled"
        ? (uniqueResult as PromiseFulfilledResult<number>).value
        : 0;
      const existing = countyAgg.get(slug);
      if (existing) {
        existing.points += pts;
        existing.unique += uniqueDelta;
      } else {
        countyAgg.set(slug, { name: county, points: pts, unique: uniqueDelta });
      }
    }

    if (countyAgg.size > 0) {
      // Re-read the displayName from inside each county tx for the same
      // freshness reason as the global lifetime update.
      const countyResults = await Promise.allSettled(
        Array.from(countyAgg.entries()).map(([slug, agg]) => {
          const statsRef = userRef.collection("countyStats").doc(slug);
          const lbRef = database.collection("leaderboards")
            .doc("lifetime_by_county").collection("counties").doc(slug);
          return database.runTransaction(async (tx) => {
            const [statsSnap, lbSnap, userSnap] = await Promise.all([
              tx.get(statsRef),
              tx.get(lbRef),
              tx.get(userRef),
            ]);
            const prev = statsSnap.data() ?? {};
            const newUnique = ((prev.uniquePostboxesClaimed as number | undefined) ?? 0) + agg.unique;
            const newTotal = ((prev.totalPoints as number | undefined) ?? 0) + agg.points;
            const freshDisplayName =
              (userSnap.data()?.displayName as string | undefined) || displayName;

            tx.set(statsRef, {
              county: agg.name,
              uniquePostboxesClaimed: newUnique,
              totalPoints: newTotal,
              updatedAt: admin.firestore.Timestamp.now(),
            }, { merge: true });

            const existingEntries =
              (lbSnap.data()?.entries ?? []) as LifetimeLeaderboardEntry[];
            const updatedEntries = mergeLifetimeEntries(
              existingEntries, userid, freshDisplayName, newUnique, newTotal
            );
            tx.set(lbRef, {
              county: agg.name,
              entries: updatedEntries,
            }, { merge: false });
          });
        })
      );
      for (const r of countyResults) {
        if (r.status === "rejected") {
          console.error("county leaderboard update failed (non-fatal):", r.reason);
        }
      }
    }

    // Fire-and-forget social notifications — not awaited so claim latency is
    // unaffected. userClaimsSnap.docs.length === 0 means this is the user's
    // first claim of the day. Suppressed for backdated flush claims: the
    // pre-fetch covers the CAPTURE day, so "first claim of the day" and the
    // daily-points overtake comparison would both be computed against the
    // wrong day.
    if (isBackdated) {
      return {
        found: true,
        claimed: earnedPoints.length,
        points: earnedPoints.reduce((s, p) => s + p, 0),
        allClaimedToday: earnedPoints.length === 0,
        dailyDate: claimDate,
      };
    }
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
    dailyDate: claimDate,
  };
}

/** How far back the streak recompute scans for claim days. Comfortably above
 *  any realistic streak while bounding the projection query. */
const STREAK_RECOMPUTE_WINDOW_DAYS = 400;

/** Recompute `users/{uid}.{lastClaimDate,streak}` from the user's distinct
 *  claim days (bounded window). Used by the backdated flush path only — see
 *  the call site in scoreClaimAt for why the incremental path can't repair
 *  out-of-order days. */
async function recomputeStreakFromClaims(userid: string, today: string): Promise<void> {
  const windowStart = new Date(today + "T00:00:00Z");
  windowStart.setUTCDate(windowStart.getUTCDate() - STREAK_RECOMPUTE_WINDOW_DAYS);
  const startDay = windowStart.toISOString().slice(0, 10);
  const snap = await database.collection("claims")
    .where("userid", "==", userid)
    .where("dailyDate", ">=", startDay)
    .select("dailyDate")
    .get();
  const days = snap.docs
    .map((d) => d.data().dailyDate as string | undefined)
    .filter((d): d is string => typeof d === "string");
  const { lastClaimDate, streak } = streakFromClaimDays(days, today);
  if (lastClaimDate === undefined) return;
  await database.collection("users").doc(userid)
    .set({ lastClaimDate, streak }, { merge: true });
}

/** Resolve a claim's location: (1) userLat/userLng stored on the claim doc
 *  (written going forward); (2) geopoint of the referenced postbox (legacy
 *  fallback). Returns undefined when neither yields a coordinate pair. */
async function resolveClaimPoint(
  claim: FirebaseFirestore.DocumentData,
): Promise<{ lat: number; lng: number } | undefined> {
  const lat = typeof claim.userLat === "number" ? (claim.userLat as number) : undefined;
  const lng = typeof claim.userLng === "number" ? (claim.userLng as number) : undefined;
  if (lat !== undefined && lng !== undefined) return { lat, lng };

  const postboxPath = claim.postboxes as string | undefined;
  const postboxKey = typeof postboxPath === "string"
    ? postboxPath.replace(/^\/postbox\//, "")
    : undefined;
  if (!postboxKey) return undefined;
  const postboxSnap = await database.collection("postbox").doc(postboxKey).get();
  if (!postboxSnap.exists) return undefined;
  const geo = getLatLng((postboxSnap.data() ?? {}).geopoint);
  if (!geo) return undefined;
  return { lat: geo.lat, lng: geo.lng };
}

/** Load one eventTime-neighbour of the claimed moment as a NeighbourPoint,
 *  fail-open (undefined) when absent or unresolvable. */
async function loadNeighbour(
  query: FirebaseFirestore.Query,
): Promise<NeighbourPoint | undefined> {
  const snap = await query.limit(1).get();
  if (snap.empty) return undefined;
  const claim = snap.docs[0].data();
  const tMs = (claim.eventTime as admin.firestore.Timestamp | undefined)?.toMillis?.();
  if (!tMs) return undefined;
  const point = await resolveClaimPoint(claim);
  if (!point) return undefined;
  return { ...point, tMs };
}

/** Two-sided anti-spoof (ROADMAP v1.5 Phase 2): the claimed moment must be
 *  physically plausible against the nearest stored claim BEFORE it and the
 *  nearest AFTER it (by `eventTime`). For a live claim the after-query is
 *  normally empty and this degrades to the historical prev-only check.
 *
 *  ⚠️ Firestore excludes documents missing the orderBy field, so claims
 *  created before the eventTime backfill are invisible here — the deploy
 *  sequence REQUIRES scripts/backfill_event_time.ts to run first.
 *
 *  Returns the implied speed vs the previous claim (persisted as
 *  `travelSpeed` for the shadow-mode detector), or undefined when skipped.
 *  Throws failed-precondition on breach. */
async function enforceNeighbourSpeedLimit(
  userid: string,
  lat: number,
  lng: number,
  eventTimeMs: number,
): Promise<number | undefined> {
  const evt = admin.firestore.Timestamp.fromMillis(eventTimeMs);
  const claims = database.collection("claims");
  const [prev, next] = await Promise.all([
    loadNeighbour(
      claims.where("userid", "==", userid)
        .where("eventTime", "<=", evt)
        .orderBy("eventTime", "desc"),
    ),
    loadNeighbour(
      claims.where("userid", "==", userid)
        .where("eventTime", ">=", evt)
        .orderBy("eventTime", "asc"),
    ),
  ]);

  const result = checkNeighbourSpeeds({ lat, lng, tMs: eventTimeMs }, prev, next);
  if (!result.ok) {
    const verb = TRAVEL_SPEED_ENFORCEMENT_ENABLED
      ? "rejected"
      : "would-reject (enforcement disabled)";
    console.warn(
      `travel-speed check ${verb} uid=${userid} ` +
      `speedPrev=${result.speedPrev?.toFixed(1) ?? "-"} ` +
      `speedNext=${result.speedNext?.toFixed(1) ?? "-"} m/min`,
    );
    if (TRAVEL_SPEED_ENFORCEMENT_ENABLED) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "You're travelling too fast — slow down before your next postbox claim."
      );
    }
  }
  return result.speedPrev;
}
