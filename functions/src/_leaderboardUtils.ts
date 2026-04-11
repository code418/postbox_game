import * as admin from "firebase-admin";

type Firestore = admin.firestore.Firestore;

/** Returns YYYY-MM-DD of the Monday of the week containing the given date string. */
function getWeekStart(today: string): string {
  const d = new Date(today + "T00:00:00Z");
  const day = d.getUTCDay(); // 0=Sun, 1=Mon...
  const diff = day === 0 ? -6 : 1 - day; // shift to Monday
  d.setUTCDate(d.getUTCDate() + diff);
  return d.toISOString().slice(0, 10);
}

/** Returns YYYY-MM-DD of the 1st of the month containing the given date string. */
function getMonthStart(today: string): string {
  return today.slice(0, 7) + "-01";
}

/**
 * Returns a stable key string for the given period — used to detect when the
 * period has rolled over so stale entries from the previous period can be
 * discarded.
 *   daily   → "2026-04-11"
 *   weekly  → "week:2026-04-06"  (Monday of the week)
 *   monthly → "month:2026-04"
 */
function getPeriodKey(name: string, startDate: string): string {
  if (name === "daily") return startDate;
  if (name === "weekly") return `week:${startDate}`;
  return `month:${startDate.slice(0, 7)}`;
}

interface LeaderboardEntry {
  uid: string;
  displayName: string;
  points: number;
}

/**
 * Recomputes the current user's total points for each leaderboard period from
 * the claims collection, then upserts their entry in leaderboards/{period}.
 */
export async function updateUserLeaderboards(
  uid: string,
  displayName: string,
  today: string,
  db: Firestore
): Promise<void> {
  const weekStart = getWeekStart(today);
  const monthStart = getMonthStart(today);

  const periods: Array<{ name: string; startDate: string; exact?: boolean }> = [
    { name: "daily", startDate: today, exact: true },
    { name: "weekly", startDate: weekStart },
    { name: "monthly", startDate: monthStart },
  ];

  await Promise.all(
    periods.map(async ({ name, startDate, exact }) => {
      // Sum points from claims for this user in the period.
      // Daily uses an equality query; weekly/monthly use a range query.
      const claimsSnap = await (exact
        ? db.collection("claims").where("userid", "==", uid).where("dailyDate", "==", startDate)
        : db.collection("claims").where("userid", "==", uid).where("dailyDate", ">=", startDate)
      ).get();

      const claimsForPeriod = claimsSnap.docs;

      const userPoints = claimsForPeriod.reduce(
        (sum, d) => sum + ((d.data().points as number) ?? 0),
        0
      );

      const leaderboardRef = db.collection("leaderboards").doc(name);
      const currentPeriodKey = getPeriodKey(name, startDate);

      await db.runTransaction(async (tx) => {
        const leaderboardSnap = await tx.get(leaderboardRef);
        const data = leaderboardSnap.data();

        // If the stored periodKey differs from the current period, the leaderboard
        // belongs to a previous period — discard all stale entries so users who
        // haven't played this period don't carry over old scores.
        const storedPeriodKey = data?.periodKey as string | undefined;
        const existing: LeaderboardEntry[] =
          storedPeriodKey === currentPeriodKey
            ? ((data?.entries as LeaderboardEntry[]) ?? [])
            : [];

        // Upsert this user's entry
        const otherEntries = existing.filter((e) => e.uid !== uid);
        const updatedEntries: LeaderboardEntry[] = [
          ...otherEntries,
          { uid, displayName, points: userPoints },
        ]
          .sort((a, b) => b.points - a.points)
          .slice(0, 100); // keep top 100

        tx.set(leaderboardRef, { periodKey: currentPeriodKey, entries: updatedEntries }, { merge: false });
      });
    })
  );
}
