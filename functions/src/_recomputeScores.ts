import "./adminInit";
import * as admin from "firebase-admin";
import { pointsForMonarch } from "./_getPoints";
import { getTodayLondon } from "./_dateUtils";
import {
  updateUserLeaderboards,
  mergeLifetimeEntries,
  LifetimeLeaderboardEntry,
  getWeekStart,
  getMonthStart,
} from "./_leaderboardUtils";

type Firestore = admin.firestore.Firestore;

/** Firestore batched writes max out at 500 ops; 400 leaves headroom. */
const WRITE_BATCH_SIZE = 400;

/**
 * Pure helper: max points earned on any single day, given a list of
 * { dailyDate, points } claim records. Exported for unit testing.
 */
export function maxDailyFromClaims(
  claims: Array<{ dailyDate?: string; points?: number }>
): number {
  const byDay = new Map<string, number>();
  for (const c of claims) {
    if (typeof c.dailyDate !== "string") continue;
    byDay.set(c.dailyDate, (byDay.get(c.dailyDate) ?? 0) + (typeof c.points === "number" ? c.points : 0));
  }
  let max = 0;
  for (const v of byDay.values()) if (v > max) max = v;
  return max;
}

export interface RepointResult {
  /** uid → total points delta (newPoints − oldPoints) summed over that user's claims on the box. */
  deltaByUid: Map<string, number>;
  claimCount: number;
}

/**
 * Rewrites the stored `points`/`monarch` on every claim for a single postbox
 * to reflect a new cypher, in batches. Records an audit trail
 * (`correctedAt`, `correctedFromMonarch`, `correctedFromPoints`). Returns the
 * per-user points delta so callers can adjust lifetime / per-county totals
 * without re-deriving the county for every claim.
 */
export async function repointClaimsForPostbox(
  db: Firestore,
  postboxKey: string,
  newMonarch: string | null
): Promise<RepointResult> {
  const newPts = pointsForMonarch(newMonarch);
  const snap = await db
    .collection("claims")
    .where("postboxes", "==", `/postbox/${postboxKey}`)
    .get();

  const deltaByUid = new Map<string, number>();
  const now = admin.firestore.Timestamp.now();
  const plain = !(typeof newMonarch === "string" && newMonarch.length > 0);

  const batches: admin.firestore.WriteBatch[] = [];
  let rewritten = 0;
  for (let i = 0; i < snap.docs.length; i += WRITE_BATCH_SIZE) {
    const batch = db.batch();
    let writesInBatch = 0;
    for (const doc of snap.docs.slice(i, i + WRITE_BATCH_SIZE)) {
      const d = doc.data();
      const uid = d.userid as string | undefined;
      const oldPts = typeof d.points === "number" ? d.points : 0;
      const currentMonarch = (typeof d.monarch === "string" && d.monarch.length > 0) ? d.monarch : null;
      const targetMonarch = plain ? null : newMonarch;
      // Skip claims that already match the target state. Two reasons:
      //  - Avoids re-stamping correctedFromMonarch / correctedFromPoints with
      //    the post-correction values (which would happen on a retry after a
      //    partial-success run), corrupting the audit trail by losing the
      //    real pre-correction values.
      //  - Saves writes on no-op admin retries.
      if (currentMonarch === targetMonarch && oldPts === newPts) continue;
      const update: Record<string, unknown> = {
        points: newPts,
        correctedAt: now,
        correctedFromMonarch: d.monarch ?? null,
        correctedFromPoints: oldPts,
        monarch: plain ? admin.firestore.FieldValue.delete() : newMonarch,
      };
      batch.set(doc.ref, update, { merge: true });
      writesInBatch++;
      if (uid) deltaByUid.set(uid, (deltaByUid.get(uid) ?? 0) + (newPts - oldPts));
    }
    if (writesInBatch > 0) {
      batches.push(batch);
      rewritten += writesInBatch;
    }
  }
  await Promise.all(batches.map((b) => b.commit()));

  return { deltaByUid, claimCount: rewritten };
}

/**
 * Re-derives one user's score aggregates from the claims collection after a
 * retroactive points change, and refreshes every leaderboard they appear on:
 *  - users/{uid}: lifetimePoints, uniquePostboxesClaimed, maxDailyPoints, and
 *    the daily/weekly/monthly period totals + markers (re-summed from claims);
 *  - leaderboards/{daily,weekly,monthly}: via updateUserLeaderboards;
 *  - leaderboards/lifetime: via mergeLifetimeEntries;
 *  - users/{uid}/countyStats/{slug} and
 *    leaderboards/lifetime_by_county/counties/{slug}: total points adjusted by
 *    `countyDelta` (the box's county is fixed, so an increment is exact).
 *
 * Period totals are never reset server-side, so re-summing them here keeps
 * them authoritative without the staleness concerns the home widget handles.
 */
export async function recomputeUserAggregates(
  db: Firestore,
  uid: string,
  today: string,
  countyDelta: number,
  countySlugVal: string | null,
  countyName: string | null
): Promise<void> {
  const userRef = db.collection("users").doc(uid);
  const userSnap = await userRef.get();
  const displayName =
    (userSnap.data()?.displayName as string | undefined) || `Player_${uid.slice(0, 6)}`;

  // Re-derive maxDailyPoints from claims. A cypher correction can change the
  // best day's total (re-pointing dropped its sum below another day's), and
  // startScoring's per-claim max(stored, today's sum) only catches further
  // upward moves — never the downward correction here, so we have to SET.
  const allClaims = await db.collection("claims").where("userid", "==", uid).get();
  const maxDailyPoints = maxDailyFromClaims(allClaims.docs.map((d) => d.data() as { dailyDate?: string; points?: number }));

  // Re-sum + rewrite the per-period leaderboards (daily/weekly/monthly).
  const periodSums = await updateUserLeaderboards(uid, displayName, today, db);
  const weekStart = getWeekStart(today);
  const monthStart = getMonthStart(today);

  // Lifetime: write user doc + leaderboards/lifetime atomically.
  //
  // lifetimePoints is updated by DELTA — `countyDelta` is the user's total
  // points change for the rewritten claims on the affected postbox. Applying
  // it inside the transaction (rather than SET-ing a value computed from a
  // pre-transaction claims sum) closes a race: a concurrent startScoring
  // claim could otherwise commit a higher lifetimePoints between our claims
  // read and our tx commit, and our SET would overwrite that fresh total
  // with the stale pre-claim value — leaving the user permanently short by
  // that claim's points.
  //
  // uniquePostboxesClaimed isn't written here: a cypher correction never
  // adds or removes unique boxes, so we read the current value inside the
  // tx and use it only for the leaderboard entry. A SET-from-claims would
  // have the same race as lifetimePoints did (concurrent first-claim of a
  // new unique box would be overwritten).
  try {
    const lifetimeRef = db.collection("leaderboards").doc("lifetime");
    await db.runTransaction(async (tx) => {
      const [uSnap, lSnap] = await Promise.all([tx.get(userRef), tx.get(lifetimeRef)]);
      const freshDisplayName =
        (uSnap.data()?.displayName as string | undefined) || displayName;
      const currentLifetime = (uSnap.data()?.lifetimePoints as number | undefined) ?? 0;
      const newLifetimePoints = currentLifetime + countyDelta;
      const currentUnique = (uSnap.data()?.uniquePostboxesClaimed as number | undefined) ?? 0;
      // Only stamp the per-period markers when the user actually has claims
      // in that period. Otherwise the rescore would overwrite a stale-but-
      // truthful marker (e.g. yesterday) with today, and downstream code
      // that treats `dailyDate === today` as evidence of a claim (notably
      // shouldNotifyFirstClaim / shouldNotifyOvertake) would wrongly skip
      // notifications for a user who hasn't claimed today.
      const userUpdate: Record<string, unknown> = {
        lifetimePoints: newLifetimePoints,
        maxDailyPoints,
        dailyPoints: periodSums.dailyPoints,
        weeklyPoints: periodSums.weeklyPoints,
        monthlyPoints: periodSums.monthlyPoints,
      };
      if (periodSums.dailyPoints > 0) userUpdate.dailyDate = today;
      if (periodSums.weeklyPoints > 0) userUpdate.weekStart = weekStart;
      if (periodSums.monthlyPoints > 0) userUpdate.monthStart = monthStart;
      tx.set(userRef, userUpdate, { merge: true });
      const existing = (lSnap.data()?.entries ?? []) as LifetimeLeaderboardEntry[];
      const updated = mergeLifetimeEntries(existing, uid, freshDisplayName, currentUnique, newLifetimePoints);
      tx.set(lifetimeRef, { periodKey: "lifetime", entries: updated }, { merge: false });
    });
  } catch (err) {
    console.error(`recomputeUserAggregates: lifetime update failed for ${uid}:`, err);
  }

  // Per-county lifetime: only the corrected box's county is affected.
  if (countySlugVal && countyDelta !== 0) {
    try {
      const statsRef = userRef.collection("countyStats").doc(countySlugVal);
      const lbRef = db
        .collection("leaderboards")
        .doc("lifetime_by_county")
        .collection("counties")
        .doc(countySlugVal);
      await db.runTransaction(async (tx) => {
        const [sSnap, lbSnap, uSnap] = await Promise.all([tx.get(statsRef), tx.get(lbRef), tx.get(userRef)]);
        const prev = sSnap.data() ?? {};
        const newTotal = ((prev.totalPoints as number | undefined) ?? 0) + countyDelta;
        const newUnique = (prev.uniquePostboxesClaimed as number | undefined) ?? 0;
        const name = (prev.county as string | undefined) || countyName || countySlugVal;
        const freshDisplayName =
          (uSnap.data()?.displayName as string | undefined) || displayName;
        tx.set(
          statsRef,
          { county: name, totalPoints: newTotal, uniquePostboxesClaimed: newUnique, updatedAt: admin.firestore.Timestamp.now() },
          { merge: true }
        );
        const existing = (lbSnap.data()?.entries ?? []) as LifetimeLeaderboardEntry[];
        const updated = mergeLifetimeEntries(existing, uid, freshDisplayName, newUnique, newTotal);
        tx.set(lbRef, { county: name, entries: updated }, { merge: false });
      });
    } catch (err) {
      console.error(`recomputeUserAggregates: county update failed for ${uid}/${countySlugVal}:`, err);
    }
  }
}

/**
 * Orchestrates a retroactive rescore after a postbox's cypher is corrected:
 * rewrite all of its claims, then recompute each affected user's aggregates
 * and leaderboards. `countySlugVal`/`countyName` are the box's county (fixed
 * by the correction). Returns counts for the caller to surface to the admin.
 */
export async function rescoreAfterCypherChange(
  db: Firestore,
  postboxKey: string,
  newMonarch: string | null,
  countySlugVal: string | null,
  countyName: string | null,
  today: string = getTodayLondon()
): Promise<{ rescoredClaims: number; affectedUsers: number }> {
  const { deltaByUid, claimCount } = await repointClaimsForPostbox(db, postboxKey, newMonarch);
  // Users whose point delta is 0 (corrected cypher maps to the same score —
  // e.g. GR→GVR are both 4 pts) had their claims' monarch / audit fields
  // updated by repointClaimsForPostbox, but their lifetimePoints, period
  // sums, maxDailyPoints and county totals are all unchanged. Skip them so
  // the post-correction sweep stays bounded by users actually affected
  // numerically rather than every claimant of the box.
  const affected = Array.from(deltaByUid.entries()).filter(([, delta]) => delta !== 0);
  await Promise.allSettled(
    affected.map(([uid, delta]) =>
      recomputeUserAggregates(db, uid, today, delta, countySlugVal, countyName)
    )
  );
  return { rescoredClaims: claimCount, affectedUsers: affected.length };
}
