import "./adminInit";
import * as admin from "firebase-admin";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { logger } from "firebase-functions";
import { getTodayLondon } from "./_dateUtils";
import {
  getWeekStart,
  getMonthStart,
  getPeriodKey,
  LeaderboardEntry,
} from "./_leaderboardUtils";

const db = admin.firestore();

/**
 * Queries all claims in [startDate, endDate], aggregates points per user,
 * fetches display names, and writes the top-100 entries to leaderboards/{name}.
 *
 * If startDate > endDate (i.e. a brand-new period with no days elapsed yet),
 * the leaderboard is written as empty with the new periodKey.
 *
 * Exported for unit testing; production callers pass the module-level `db`.
 */
export async function rebuildPeriodLeaderboard(
  name: string,
  startDate: string,
  endDate: string,
  database: admin.firestore.Firestore = db
): Promise<void> {
  const periodKey = getPeriodKey(name, startDate);
  const leaderboardRef = database.collection("leaderboards").doc(name);

  if (startDate > endDate) {
    // New period (e.g. Monday for weekly, 1st for monthly) — no claims yet.
    // Use a transaction so we don't clobber entries already written by
    // updateUserLeaderboards for a claim that landed between midnight and
    // this sweep running. Only initialise when the stored periodKey still
    // belongs to the previous period.
    await database.runTransaction(async (tx) => {
      const snap = await tx.get(leaderboardRef);
      const storedPeriodKey = snap.data()?.periodKey as string | undefined;
      if (storedPeriodKey === periodKey) return;
      tx.set(leaderboardRef, { periodKey, entries: [] }, { merge: false });
    });
    return;
  }

  const claimsSnap = await database
    .collection("claims")
    .where("dailyDate", ">=", startDate)
    .where("dailyDate", "<=", endDate)
    .get();

  // Aggregate points per user.
  const userPoints = new Map<string, number>();
  for (const doc of claimsSnap.docs) {
    const d = doc.data();
    const uid = d.userid as string;
    const pts = (d.points as number | undefined) ?? 0;
    userPoints.set(uid, (userPoints.get(uid) ?? 0) + pts);
  }

  // Fetch display names in parallel.
  const uids = Array.from(userPoints.keys());
  const userDocs = await Promise.all(
    uids.map((uid) => database.collection("users").doc(uid).get())
  );

  const entries: LeaderboardEntry[] = [];
  for (let i = 0; i < uids.length; i++) {
    const uid = uids[i];
    const pts = userPoints.get(uid)!;
    if (pts <= 0) continue;
    const displayName =
      (userDocs[i].data()?.displayName as string | undefined) ??
      `Player_${uid.slice(0, 6)}`;
    entries.push({ uid, displayName, points: pts });
  }

  entries.sort((a, b) => b.points - a.points);

  // Only overwrite when the leaderboard still belongs to the previous period.
  // If storedPeriodKey already equals the current periodKey, updateUserLeaderboards
  // has been keeping the board up to date incrementally — clobbering it here
  // would drop entries from claims that landed between our claims read above
  // and this write. Drift correction runs at the period boundary; mid-period
  // integrity is maintained by the per-claim transactions.
  await database.runTransaction(async (tx) => {
    const snap = await tx.get(leaderboardRef);
    const storedPeriodKey = snap.data()?.periodKey as string | undefined;
    if (storedPeriodKey === periodKey) return;
    tx.set(leaderboardRef, { periodKey, entries: entries.slice(0, 100) }, { merge: false });
  });
}

// Run at midnight London time every day.
// Manually trigger via https://console.cloud.google.com/cloudscheduler
export const newDayScoreboard = onSchedule(
  { schedule: "0 0 * * *", timeZone: "Europe/London" },
  async (_event) => {
    const today = getTodayLondon();

    const yesterdayDate = new Date(today + "T00:00:00Z");
    yesterdayDate.setUTCDate(yesterdayDate.getUTCDate() - 1);
    const yesterday = yesterdayDate.toISOString().slice(0, 10);

    const weekStart = getWeekStart(today);
    const monthStart = getMonthStart(today);

    logger.info(
      `New day rollover: today=${today}, yesterday=${yesterday}, weekStart=${weekStart}, monthStart=${monthStart}`
    );

    // 1. Reset daily — only when the doc still carries yesterday's periodKey.
    // If updateUserLeaderboards has already rotated it (a claim landed in the
    // first seconds of the new day), leave those fresh entries alone.
    const dailyRef = db.collection("leaderboards").doc("daily");
    const todayKey = getPeriodKey("daily", today);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(dailyRef);
      const storedPeriodKey = snap.data()?.periodKey as string | undefined;
      if (storedPeriodKey === todayKey) return;
      tx.set(dailyRef, { periodKey: todayKey, entries: [] }, { merge: false });
    });
    logger.info("Daily leaderboard reset");

    // 2. Rebuild weekly and monthly from source-of-truth claims.
    //    allSettled so a failure in one doesn't abort the other.
    const [weeklyResult, monthlyResult] = await Promise.allSettled([
      rebuildPeriodLeaderboard("weekly", weekStart, yesterday),
      rebuildPeriodLeaderboard("monthly", monthStart, yesterday),
    ]);

    if (weeklyResult.status === "rejected") {
      logger.error("Weekly leaderboard rebuild failed:", weeklyResult.reason);
    } else {
      logger.info("Weekly leaderboard rebuilt");
    }

    if (monthlyResult.status === "rejected") {
      logger.error("Monthly leaderboard rebuild failed:", monthlyResult.reason);
    } else {
      logger.info("Monthly leaderboard rebuilt");
    }

    // Note: per-user dailyPoints/weeklyPoints/monthlyPoints are NOT reset here.
    // An earlier implementation did a merge-set `{ dailyPoints: 0, ... }` across
    // all user docs, but that races with startScoring's lifetime transaction:
    // a user who claimed in the first seconds of the new day would have their
    // freshly-written dailyPoints overwritten back to 0 by this sweep, and the
    // next claim's INCREMENT would start from 0 instead of their running total.
    // Staleness is handled by callers reading these fields (home widget,
    // friends leaderboard) via the per-period markers (dailyDate, weekStart,
    // monthStart) written inside the same lifetime tx as the points.
  }
);
