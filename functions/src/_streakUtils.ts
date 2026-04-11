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
