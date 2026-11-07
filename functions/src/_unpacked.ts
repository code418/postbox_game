/**
 * "Your Postboxes Unpacked" — the annual, Wrapped-style recap rolled out each
 * December. Pure helpers only (no Firestore): the snapshot builder in
 * buildUnpacked.ts streams claims through [UnpackedAccumulator], joins the
 * postbox docs for county/reference, then [finalizeUnpacked]s each player and
 * stamps community percentiles via [percentileRank].
 *
 * Everything here is deliberately derived from the stored claim docs
 * (`points` as actually awarded, `dailyDate` as the London claim day) rather
 * than re-scored, so the recap always agrees with the leaderboards a player
 * saw during the year — including any Remote Config points overrides and any
 * retroactive cypher corrections.
 */

/** First year the feature shipped. Account deletion erases every year from
 *  here to the current one. */
export const FIRST_UNPACKED_YEAR = 2026;

/** Every recap year that could hold a snapshot for a user, for erasure. */
export function unpackedYearsToErase(todayLondon: string): number[] {
  const current = parseInt(todayLondon.slice(0, 4), 10);
  const years: number[] = [];
  for (let y = FIRST_UNPACKED_YEAR; y <= current; y++) years.push(y);
  return years;
}

/** Bumped whenever the snapshot shape changes incompatibly, so an old client
 *  can tell a newer snapshot apart (it renders what it understands). */
export const UNPACKED_SNAPSHOT_VERSION = 1;

/** The subset of a claim doc the recap reads. */
export interface UnpackedClaim {
  userid: string;
  dailyDate: string; // "YYYY-MM-DD", London
  points: number;
  monarch?: string | null;
  postboxId: string;
}

export interface PostboxMeta {
  county?: string;
  reference?: string;
}

export interface UnpackedStats {
  year: number;
  totalClaims: number;
  uniquePostboxes: number;
  totalPoints: number;
  daysActive: number;
  firstClaimDate: string;
  lastClaimDate: string;
  longestStreak: { days: number; start: string; end: string };
  /** 1–12. Ties go to the earlier month. */
  busiestMonth: { month: number; claims: number };
  /** 1 = Monday … 7 = Sunday (ISO). Ties go to the earlier weekday. */
  favouriteWeekday: { weekday: number; claims: number };
  busiestDay: { date: string; points: number; claims: number };
  rarestFind: {
    postboxId: string;
    monarch: string | null;
    points: number;
    dailyDate: string;
    reference: string | null;
  };
  /** Claims per cypher; plain/unknown boxes are counted under "NONE". */
  monarchCounts: Record<string, number>;
  /** Most distinct boxes claimed in one county; null when no claimed box
   *  carries a county. Ties go to the alphabetically first county. */
  topCounty: { name: string; uniquePostboxes: number } | null;
  countiesVisited: number;
  /** Share of players (0–99) this player strictly beat. Filled in once every
   *  player has been finalised. */
  percentiles: { uniquePostboxes: number; totalPoints: number; longestStreak: number };
}

/** Parses the postbox id out of a claim's `postboxes` path ("/postbox/{id}"),
 *  tolerating a bare id. Returns null for anything unusable. */
export function postboxIdFromPath(path: unknown): string | null {
  if (typeof path !== "string" || path.length === 0) return null;
  const id = path.split("/").filter((s) => s.length > 0).pop();
  return id && id.length > 0 ? id : null;
}

/** ISO weekday (1 = Monday … 7 = Sunday) of a "YYYY-MM-DD" date. */
export function isoWeekday(date: string): number {
  const dow = new Date(date + "T00:00:00Z").getUTCDay(); // 0 = Sunday
  return dow === 0 ? 7 : dow;
}

function nextDay(date: string): string {
  const d = new Date(date + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString().slice(0, 10);
}

/** Longest run of consecutive days in [days] (any order, duplicates fine).
 *  Ties go to the earliest run. Unlike streakFromClaimDays (which reports the
 *  run ending at the latest day), this is the best run anywhere in the set. */
export function longestStreak(days: Iterable<string>): { days: number; start: string; end: string } {
  const sorted = [...new Set(days)].sort();
  if (sorted.length === 0) return { days: 0, start: "", end: "" };
  let best = { days: 1, start: sorted[0], end: sorted[0] };
  let runStart = sorted[0];
  let runLen = 1;
  for (let i = 1; i < sorted.length; i++) {
    if (sorted[i] === nextDay(sorted[i - 1])) {
      runLen++;
    } else {
      runStart = sorted[i];
      runLen = 1;
    }
    if (runLen > best.days) best = { days: runLen, start: runStart, end: sorted[i] };
  }
  return best;
}

/** Index of the largest value; ties resolve to the lowest index. */
function argMax(values: number[]): number {
  let best = 0;
  for (let i = 1; i < values.length; i++) if (values[i] > values[best]) best = i;
  return best;
}

/**
 * One player's running totals. Feed it claims in any order with [add]; it
 * keeps only small aggregates (sets of day strings and postbox ids), so a
 * whole year of claims across every player fits comfortably in memory.
 */
export class UnpackedAccumulator {
  claims = 0;
  points = 0;
  readonly postboxes = new Set<string>();
  readonly days = new Set<string>();
  readonly monarchCounts: Record<string, number> = {};
  readonly monthCounts = new Array<number>(12).fill(0);
  readonly weekdayCounts = new Array<number>(7).fill(0);
  readonly dayTotals = new Map<string, { points: number; claims: number }>();
  rarest: { postboxId: string; monarch: string | null; points: number; dailyDate: string } | null = null;

  constructor(readonly uid: string, readonly year: number) {}

  /** Adds a claim. Claims outside [year] are ignored (the query already
   *  bounds the range; this keeps the accumulator honest on its own). */
  add(c: UnpackedClaim): void {
    if (!c.dailyDate.startsWith(`${this.year}-`)) return;
    const points = Number.isFinite(c.points) ? c.points : 0;
    this.claims++;
    this.points += points;
    this.postboxes.add(c.postboxId);
    this.days.add(c.dailyDate);
    const monarchKey = typeof c.monarch === "string" && c.monarch.length > 0 ? c.monarch : "NONE";
    this.monarchCounts[monarchKey] = (this.monarchCounts[monarchKey] ?? 0) + 1;
    const month = parseInt(c.dailyDate.slice(5, 7), 10);
    if (month >= 1 && month <= 12) this.monthCounts[month - 1]++;
    this.weekdayCounts[isoWeekday(c.dailyDate) - 1]++;
    const day = this.dayTotals.get(c.dailyDate) ?? { points: 0, claims: 0 };
    day.points += points;
    day.claims++;
    this.dayTotals.set(c.dailyDate, day);

    // Rarest = most points; the EARLIEST such claim wins a tie (then postbox
    // id, so the result never depends on query order).
    const r = this.rarest;
    if (
      r === null ||
      points > r.points ||
      (points === r.points &&
        (c.dailyDate < r.dailyDate || (c.dailyDate === r.dailyDate && c.postboxId < r.postboxId)))
    ) {
      this.rarest = {
        postboxId: c.postboxId,
        monarch: monarchKey === "NONE" ? null : monarchKey,
        points,
        dailyDate: c.dailyDate,
      };
    }
  }
}

/**
 * Turns an accumulator into the stored snapshot. Returns null for a player
 * with no claims in the year (nothing to unpack). Percentiles are zeroed here
 * and filled in by the builder once every player is known.
 */
export function finalizeUnpacked(
  acc: UnpackedAccumulator,
  meta: ReadonlyMap<string, PostboxMeta>,
): UnpackedStats | null {
  if (acc.claims === 0 || acc.rarest === null) return null;
  const sortedDays = [...acc.days].sort();

  let busiestDay = { date: "", points: -1, claims: 0 };
  for (const date of sortedDays) {
    const t = acc.dayTotals.get(date)!;
    if (t.points > busiestDay.points) busiestDay = { date, points: t.points, claims: t.claims };
  }

  const perCounty = new Map<string, number>();
  for (const id of acc.postboxes) {
    const county = meta.get(id)?.county;
    if (typeof county === "string" && county.length > 0) {
      perCounty.set(county, (perCounty.get(county) ?? 0) + 1);
    }
  }
  let topCounty: UnpackedStats["topCounty"] = null;
  for (const [name, n] of [...perCounty.entries()].sort(([a], [b]) => a.localeCompare(b))) {
    if (topCounty === null || n > topCounty.uniquePostboxes) topCounty = { name, uniquePostboxes: n };
  }

  const month = argMax(acc.monthCounts);
  const weekday = argMax(acc.weekdayCounts);
  const ref = meta.get(acc.rarest.postboxId)?.reference;

  return {
    year: acc.year,
    totalClaims: acc.claims,
    uniquePostboxes: acc.postboxes.size,
    totalPoints: acc.points,
    daysActive: acc.days.size,
    firstClaimDate: sortedDays[0],
    lastClaimDate: sortedDays[sortedDays.length - 1],
    longestStreak: longestStreak(sortedDays),
    busiestMonth: { month: month + 1, claims: acc.monthCounts[month] },
    favouriteWeekday: { weekday: weekday + 1, claims: acc.weekdayCounts[weekday] },
    busiestDay,
    rarestFind: { ...acc.rarest, reference: typeof ref === "string" && ref.length > 0 ? ref : null },
    monarchCounts: { ...acc.monarchCounts },
    topCounty,
    countiesVisited: perCounty.size,
    percentiles: { uniquePostboxes: 0, totalPoints: 0, longestStreak: 0 },
  };
}

/**
 * Percentage (integer 0–99) of [sortedAsc] strictly below [value] — i.e. "you
 * beat X% of players". Strictly-below means a lone player, or a field where
 * everyone tied, beats 0% rather than claiming a hollow 100%. Capped at 99 so
 * the top player reads "more than 99%", never "more than 100%".
 */
export function percentileRank(sortedAsc: readonly number[], value: number): number {
  if (sortedAsc.length === 0) return 0;
  // Binary search for the first index >= value.
  let lo = 0;
  let hi = sortedAsc.length;
  while (lo < hi) {
    const mid = (lo + hi) >>> 1;
    if (sortedAsc[mid] < value) lo = mid + 1;
    else hi = mid;
  }
  return Math.min(99, Math.floor((lo / sortedAsc.length) * 100));
}

/** Fills each snapshot's `percentiles` in place against the whole field. */
export function applyPercentiles(all: UnpackedStats[]): void {
  const sorted = (f: (s: UnpackedStats) => number) => all.map(f).sort((a, b) => a - b);
  const boxes = sorted((s) => s.uniquePostboxes);
  const points = sorted((s) => s.totalPoints);
  const streaks = sorted((s) => s.longestStreak.days);
  for (const s of all) {
    s.percentiles = {
      uniquePostboxes: percentileRank(boxes, s.uniquePostboxes),
      totalPoints: percentileRank(points, s.totalPoints),
      longestStreak: percentileRank(streaks, s.longestStreak.days),
    };
  }
}

export interface UnpackedSummary {
  year: number;
  players: number;
  totalClaims: number;
  uniquePostboxes: number;
  totalPoints: number;
  /** Most-claimed cypher across everyone, excluding plain boxes; null if none. */
  topMonarch: string | null;
}

/** Community-wide totals for the summary doc. [allPostboxes] is the distinct
 *  set across every player (not the sum of each player's uniques). */
export function summarise(year: number, all: UnpackedStats[], allPostboxes: number): UnpackedSummary {
  const monarchs: Record<string, number> = {};
  let totalClaims = 0;
  let totalPoints = 0;
  for (const s of all) {
    totalClaims += s.totalClaims;
    totalPoints += s.totalPoints;
    for (const [m, n] of Object.entries(s.monarchCounts)) {
      if (m !== "NONE") monarchs[m] = (monarchs[m] ?? 0) + n;
    }
  }
  let topMonarch: string | null = null;
  for (const [m, n] of Object.entries(monarchs).sort(([a], [b]) => a.localeCompare(b))) {
    if (topMonarch === null || n > monarchs[topMonarch]) topMonarch = m;
  }
  return { year, players: all.length, totalClaims, uniquePostboxes: allPostboxes, totalPoints, topMonarch };
}

export interface UnpackedWindow {
  availableFrom: string; // inclusive London date
  availableUntil: string; // inclusive London date
}

/** The recap for [year] is open from 1 December to 15 January (London). */
export function unpackedWindow(year: number): UnpackedWindow {
  return { availableFrom: `${year}-12-01`, availableUntil: `${year + 1}-01-15` };
}

export function isWithinWindow(todayLondon: string, w: UnpackedWindow): boolean {
  return todayLondon >= w.availableFrom && todayLondon <= w.availableUntil;
}

/** Which recap year is current on [todayLondon]: the current year from
 *  December on, the previous year during the January tail of its window. */
export function unpackedYearFor(todayLondon: string): number {
  const year = parseInt(todayLondon.slice(0, 4), 10);
  return todayLondon.slice(5, 7) === "12" ? year : year - 1;
}

export interface LaunchNotifyState {
  /** Recap years whose "ready" push has already gone out. */
  sentYears?: number[];
}

/**
 * Pure decision for the once-per-year "your recap is ready" push. Fires only
 * when the snapshot exists, today is inside its window and the Remote Config
 * flag is on — and never twice for the same year, so the daily schedule can
 * keep retrying until an operator flips the flag.
 */
export function decideLaunchNotify(
  state: LaunchNotifyState | undefined,
  year: number,
  todayLondon: string,
  summaryExists: boolean,
  flagOn: boolean,
): { fire: boolean; newState: LaunchNotifyState } {
  const sentYears = state?.sentYears ?? [];
  const newState = { sentYears };
  if (!flagOn || !summaryExists) return { fire: false, newState };
  if (!isWithinWindow(todayLondon, unpackedWindow(year))) return { fire: false, newState };
  if (sentYears.includes(year)) return { fire: false, newState };
  return { fire: true, newState: { sentYears: [...sentYears, year].sort((a, b) => a - b) } };
}

/** Push body for the launch notification. */
export function launchNotifyBody(s: Pick<UnpackedStats, "year" | "uniquePostboxes">): string {
  const boxes = s.uniquePostboxes === 1 ? "1 postbox" : `${s.uniquePostboxes} postboxes`;
  return `You found ${boxes} in ${s.year}. Postman James has your year all wrapped up — come and unpack it!`;
}
