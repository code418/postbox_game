import * as admin from "firebase-admin";

type Firestore = admin.firestore.Firestore;

/** Returns YYYY-MM-DD of the Monday of the week containing the given date string. */
export function getWeekStart(today: string): string {
  const d = new Date(today + "T00:00:00Z");
  const day = d.getUTCDay(); // 0=Sun, 1=Mon...
  const diff = day === 0 ? -6 : 1 - day; // shift to Monday
  d.setUTCDate(d.getUTCDate() + diff);
  return d.toISOString().slice(0, 10);
}

/** Returns YYYY-MM-DD of the 1st of the month containing the given date string. */
export function getMonthStart(today: string): string {
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
export function getPeriodKey(name: string, startDate: string): string {
  if (name === "daily") return startDate;
  if (name === "weekly") return `week:${startDate}`;
  return `month:${startDate.slice(0, 7)}`;
}

export interface LeaderboardEntry {
  uid: string;
  displayName: string;
  points: number;
}

/**
 * Pure function: upsert a user's entry into a period leaderboard snapshot.
 * Exported for unit testing. The Firestore transaction wrapper calls this
 * with the existing snapshot entries, then writes the returned array.
 *
 * - Removes any prior entry for `uid`.
 * - Adds a new entry if `userPoints > 0`; omits it if zero (name-change
 *   before first claim in a period should not add a 0-point entry).
 * - Sorts descending by points and caps at `limit` entries (default 100).
 */
export function mergePeriodEntries(
  existing: LeaderboardEntry[],
  uid: string,
  displayName: string,
  userPoints: number,
  limit = 100
): LeaderboardEntry[] {
  const others = existing.filter((e) => e.uid !== uid);
  return [
    ...others,
    ...(userPoints > 0 ? [{ uid, displayName, points: userPoints }] : []),
  ]
    .sort((a, b) => b.points - a.points)
    .slice(0, limit);
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

  // allSettled so a single period failure doesn't abort the other two.
  // Each period transaction is independent and idempotent; partial success
  // is always better than retrying all three when only one failed.
  const results = await Promise.allSettled(
    periods.map(async ({ name, startDate, exact }) => {
      // Sum points from claims for this user in the period.
      // Daily: equality query. Weekly/monthly: range query with an upper bound
      // of today to exclude any claims that somehow carry a future dailyDate.
      const claimsSnap = await (exact
        ? db.collection("claims").where("userid", "==", uid).where("dailyDate", "==", startDate)
        : db.collection("claims").where("userid", "==", uid).where("dailyDate", ">=", startDate).where("dailyDate", "<=", today)
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

        // Upsert this user's entry, or remove it if they have 0 points (e.g.
        // updateDisplayName called before any claim in this period).
        const updatedEntries = mergePeriodEntries(existing, uid, displayName, userPoints);
        tx.set(leaderboardRef, { periodKey: currentPeriodKey, entries: updatedEntries }, { merge: false });
      });
    })
  );
  for (const result of results) {
    if (result.status === "rejected") {
      console.error("leaderboard period update failed:", result.reason);
    }
  }
}

export interface LifetimeLeaderboardEntry {
  uid: string;
  displayName: string;
  uniquePostboxesClaimed: number;
  totalPoints: number;
}

/**
 * Pure function: upsert a user's entry into the lifetime leaderboard snapshot.
 * Exported for unit testing.
 *
 * - Removes any prior entry for `uid`.
 * - Adds an entry if either `uniquePostboxesClaimed > 0` or `totalPoints > 0`.
 * - Sorts descending by `uniquePostboxesClaimed` (secondary: totalPoints) and
 *   caps at `limit` entries (default 100).
 */
export function mergeLifetimeEntries(
  existing: LifetimeLeaderboardEntry[],
  uid: string,
  displayName: string,
  uniquePostboxesClaimed: number,
  totalPoints: number,
  limit = 100
): LifetimeLeaderboardEntry[] {
  const others = existing.filter((e) => e.uid !== uid);
  return [
    ...others,
    ...(uniquePostboxesClaimed > 0 || totalPoints > 0
      ? [{ uid, displayName, uniquePostboxesClaimed, totalPoints }]
      : []),
  ]
    .sort((a, b) =>
      b.uniquePostboxesClaimed !== a.uniquePostboxesClaimed
        ? b.uniquePostboxesClaimed - a.uniquePostboxesClaimed
        : b.totalPoints - a.totalPoints
    )
    .slice(0, limit);
}

/**
 * Upserts the user's lifetime entry in leaderboards/lifetime.
 * Sorts by uniquePostboxesClaimed descending, keeps top 100.
 * periodKey is always "lifetime" — no rollover.
 */
export async function updateLifetimeLeaderboard(
  uid: string,
  displayName: string,
  uniquePostboxesClaimed: number,
  totalPoints: number,
  db: Firestore
): Promise<void> {
  const ref = db.collection("leaderboards").doc("lifetime");
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const existing: LifetimeLeaderboardEntry[] =
      (snap.data()?.entries as LifetimeLeaderboardEntry[]) ?? [];

    const updated = mergeLifetimeEntries(existing, uid, displayName, uniquePostboxesClaimed, totalPoints);
    tx.set(ref, { periodKey: "lifetime", entries: updated }, { merge: false });
  });
}
