export function getTodayLondon(): string {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/London',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(new Date());
  const y = parts.find(p => p.type === 'year')!.value;
  const m = parts.find(p => p.type === 'month')!.value;
  const d = parts.find(p => p.type === 'day')!.value;
  return `${y}-${m}-${d}`;
  // Returns "YYYY-MM-DD" using Europe/London timezone; handles BST/GMT automatically
}

/**
 * Returns the calendar day before `dateStr` ("YYYY-MM-DD") as "YYYY-MM-DD".
 *
 * The date string is interpreted at UTC midnight for the subtraction. This is
 * the same trick used inline in newDayScoreboard for computing "yesterday" and
 * is DST-safe: we only ever move a whole day in a fixed-offset (UTC) frame, so
 * no wall-clock hour can be skipped or repeated.
 */
export function previousDay(dateStr: string): string {
  const d = new Date(dateStr + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() - 1);
  return d.toISOString().slice(0, 10);
}

/**
 * Returns the current hour and minute in Europe/London (24-hour clock),
 * accounting for BST/GMT automatically. Used to place "now" within the
 * streak-reminder polling window.
 */
export function getLondonHourMinute(): { hour: number; minute: number } {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/London',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).formatToParts(new Date());
  const hourStr = parts.find(p => p.type === 'hour')!.value;
  const minute = parseInt(parts.find(p => p.type === 'minute')!.value, 10);
  // Intl can emit "24" for midnight under hour12:false; normalise to 0.
  const hour = parseInt(hourStr, 10) % 24;
  return { hour, minute };
}
