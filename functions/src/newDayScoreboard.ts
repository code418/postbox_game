import "./adminInit";
import * as admin from "firebase-admin";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { logger } from "firebase-functions";
import { getTodayLondon } from "./_dateUtils";
import {
  getWeekStart,
  getMonthStart,
  getPeriodKey,
  getPeriodResetFields,
  LeaderboardEntry,
} from "./_leaderboardUtils";

const db = admin.firestore();

/**
 * Queries all claims in [startDate, endDate], aggregates points per user,
 * fetches display names, and writes the top-100 entries to leaderboards/{name}.
 *
 * If startDate > endDate (i.e. a brand-new period with no days elapsed yet),
 * the leaderboard is written as empty with the new periodKey.
 */
async function rebuildPeriodLeaderboard(
  name: string,
  startDate: string,
  endDate: string
): Promise<void> {
  const periodKey = getPeriodKey(name, startDate);

  if (startDate > endDate) {
    // New period (e.g. Monday for weekly, 1st for monthly) — no claims yet.
    await db.collection("leaderboards").doc(name).set(
      { periodKey, entries: [] },
      { merge: false }
    );
    return;
  }

  const claimsSnap = await db
    .collection("claims")
    .where("dailyDate", ">=", startDate)
    .where("dailyDate", "<=", endDate)
    .get();

  // Aggregate points per user.
  const userPoints = new Map<string, number>();
  for (const doc of claimsSnap.docs) {
    const d = doc.data();
    const uid = d.userid as string;
    const pts = (d.points as number) ?? 0;
    userPoints.set(uid, (userPoints.get(uid) ?? 0) + pts);
  }

  // Fetch display names in parallel.
  const uids = Array.from(userPoints.keys());
  const userDocs = await Promise.all(
    uids.map((uid) => db.collection("users").doc(uid).get())
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

  await db.collection("leaderboards").doc(name).set(
    { periodKey, entries: entries.slice(0, 100) },
    { merge: false }
  );
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

    // 1. Reset daily — starts empty; updateUserLeaderboards fills it as users play.
    await db.collection("leaderboards").doc("daily").set(
      { periodKey: getPeriodKey("daily", today), entries: [] },
      { merge: false }
    );
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

    // 3. Reset per-user period point fields.
    // dailyPoints resets every day; weeklyPoints on Mondays; monthlyPoints on the 1st.
    try {
      const resetFields = getPeriodResetFields(today, weekStart, monthStart);
      const usersSnap = await db.collection("users").get();
      const BATCH_LIMIT = 499;
      const batches: admin.firestore.WriteBatch[] = [];
      let batch: admin.firestore.WriteBatch = db.batch();
      let batchCount = 0;
      for (const doc of usersSnap.docs) {
        batch.update(doc.ref, resetFields);
        batchCount++;
        if (batchCount === BATCH_LIMIT) {
          batches.push(batch);
          batch = db.batch();
          batchCount = 0;
        }
      }
      if (batchCount > 0) batches.push(batch);
      await Promise.all(batches.map((b) => b.commit()));
      logger.info(
        `Period fields reset: [${Object.keys(resetFields).join(", ")}] across ${usersSnap.docs.length} users`
      );
    } catch (resetErr) {
      logger.error("Period point reset failed (non-fatal):", resetErr);
    }
  }
);
