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

  const periods: Array<{ name: string; startDate: string }> = [
    { name: "daily", startDate: today },
    { name: "weekly", startDate: weekStart },
    { name: "monthly", startDate: monthStart },
  ];

  await Promise.all(
    periods.map(async ({ name, startDate }) => {
      // Sum points from claims for this user in the period
      const claimsSnap = await db
        .collection("claims")
        .where("userid", "==", uid)
        .where("dailyDate", ">=", startDate)
        .get();

      // For daily we also need an upper bound to avoid bleeding into future days
      const claimsForPeriod =
        name === "daily"
          ? claimsSnap.docs.filter((d) => d.data().dailyDate === today)
          : claimsSnap.docs;

      const userPoints = claimsForPeriod.reduce(
        (sum, d) => sum + ((d.data().points as number) ?? 0),
        0
      );

      const leaderboardRef = db.collection("leaderboards").doc(name);

      await db.runTransaction(async (tx) => {
        const leaderboardSnap = await tx.get(leaderboardRef);
        const existing: LeaderboardEntry[] =
          (leaderboardSnap.data()?.entries as LeaderboardEntry[]) ?? [];

        // Upsert this user's entry
        const otherEntries = existing.filter((e) => e.uid !== uid);
        const updatedEntries: LeaderboardEntry[] = [
          ...otherEntries,
          { uid, displayName, points: userPoints },
        ]
          .sort((a, b) => b.points - a.points)
          .slice(0, 100); // keep top 100

        tx.set(leaderboardRef, { entries: updatedEntries }, { merge: false });
      });
    })
  );
}
