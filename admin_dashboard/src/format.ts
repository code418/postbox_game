// Small, pure display formatters (en-GB).

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

export function relativeTime(ms: number | null, now: number = Date.now()): string {
  if (ms === null) return "unknown time";
  const d = now - ms;
  if (d < MINUTE) return "just now";
  if (d < HOUR) return `${Math.floor(d / MINUTE)} min ago`;
  if (d < DAY) return `${Math.floor(d / HOUR)} h ago`;
  const days = Math.floor(d / DAY);
  if (days < 60) return `${days} day${days === 1 ? "" : "s"} ago`;
  return `${Math.floor(days / 30)} months ago`;
}

export function dateTime(ms: number | null): string {
  if (ms === null) return "unknown";
  return new Date(ms).toLocaleString("en-GB", { day: "numeric", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" });
}

export function metres(m: number | null): string {
  if (m === null) return "unknown distance";
  return m >= 1000 ? `${(m / 1000).toFixed(1)} km` : `${Math.round(m)} m`;
}

/** Signed points with a real minus sign: "+5", "−5", "0". */
export function signed(n: number): string {
  if (n > 0) return `+${n}`;
  if (n < 0) return `−${Math.abs(n)}`;
  return "0";
}

export function coords(lat: number, lng: number): string {
  return `${lat.toFixed(6)}, ${lng.toFixed(6)}`;
}

export function percent(fraction: number | null): string {
  return fraction === null ? "no decisions yet" : `${Math.round(fraction * 100)}%`;
}

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

/** Street View capture month "2023-06" → "June 2023". */
export function monthYear(yyyyMm: string | null): string | null {
  const m = yyyyMm === null ? null : /^(\d{4})-(\d{2})$/.exec(yyyyMm);
  const month = m ? MONTHS[Number(m[2]) - 1] : undefined;
  return m && month ? `${month} ${m[1]}` : null;
}

/** Whole years from a capture month ("YYYY-MM") to a later moment; null if
 *  either is unknown. */
export function yearsBefore(yyyyMm: string | null, ms: number | null): number | null {
  const m = yyyyMm === null ? null : /^(\d{4})-(\d{2})$/.exec(yyyyMm);
  if (!m || ms === null) return null;
  const at = new Date(ms);
  const months = (at.getUTCFullYear() - Number(m[1])) * 12 + (at.getUTCMonth() + 1 - Number(m[2]));
  return Math.max(0, Math.floor(months / 12));
}

export function idEditorUrl(opts: { overpassId?: number | null; lat?: number | null; lng?: number | null }): string | null {
  if (typeof opts.overpassId === "number") return `https://www.openstreetmap.org/edit?editor=id&node=${opts.overpassId}`;
  if (typeof opts.lat === "number" && typeof opts.lng === "number") return `https://www.openstreetmap.org/edit#map=19/${opts.lat}/${opts.lng}`;
  return null;
}
