/**
 * Computes the new streak value given the current state.
 *
 * @param lastClaimDate  ISO date string (YYYY-MM-DD) of the last claim, or undefined.
 * @param currentStreak  The current streak count (default 0).
 * @param today          Today's ISO date string (from getTodayLondon).
 * @param yesterday      Yesterday's ISO date string (today minus 1 day).
 * @returns null if the streak should NOT be updated (already claimed today),
 *          or the new streak value to write.
 */
export function computeNewStreak(
  lastClaimDate: string | undefined,
  currentStreak: number,
  today: string,
  yesterday: string
): number | null {
  if (lastClaimDate === today) return null; // already updated today
  if (lastClaimDate === yesterday) return currentStreak + 1;
  return 1;
}

/** Returns the calendar day before `dateStr` at UTC midnight (DST-safe: whole
 *  days in a fixed-offset frame — the same trick as _dateUtils.previousDay,
 *  duplicated here to keep this module dependency-free and pure). */
function dayBefore(dateStr: string): string {
  const d = new Date(dateStr + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() - 1);
  return d.toISOString().slice(0, 10);
}

/**
 * Recompute the stored streak state from a user's distinct claim days
 * (ROADMAP v1.5, offline play Phase 2).
 *
 * [computeNewStreak] is forward-only and cannot handle out-of-order arrival:
 * a live claim on Wednesday landing BEFORE a Tuesday-dated offline flush
 * resets the streak to 1 with no repair path. The flush path calls this
 * instead: dedupe the claim days, drop anything after [today] (defensive),
 * and count the consecutive run ending at the most recent remaining day.
 * This is what turns a late flush into a SAVED streak. The live claim path
 * keeps the cheap incremental [computeNewStreak].
 *
 * Returns the `{lastClaimDate, streak}` pair exactly as stored on
 * `users/{uid}` (`{undefined, 0}` when no valid days exist).
 */
export function streakFromClaimDays(
  claimDays: string[],
  today: string,
): { lastClaimDate: string | undefined; streak: number } {
  const days = [...new Set(claimDays)].filter((d) => d <= today).sort();
  if (days.length === 0) return { lastClaimDate: undefined, streak: 0 };
  const last = days[days.length - 1];
  let streak = 1;
  let cursor = last;
  for (let i = days.length - 2; i >= 0; i--) {
    if (days[i] !== dayBefore(cursor)) break;
    cursor = days[i];
    streak++;
  }
  return { lastClaimDate: last, streak };
}
