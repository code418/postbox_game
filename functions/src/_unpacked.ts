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

import { pointsForMonarch } from "./_getPoints";

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
 *  can tell a newer snapshot apart (it renders what it understands). Adding
 *  a field (as `busiestDays` was) is compatible and needs no bump. */
export const UNPACKED_SNAPSHOT_VERSION = 1;

/** How many days the "Busiest days" list keeps. */
export const BUSIEST_DAYS_LIMIT = 3;

/** How many friends the "Longest streak" comparison lists. */
export const FRIEND_STREAKS_LIMIT = 5;

/** How many counties "Home turf" lists after the top one. */
export const OTHER_COUNTIES_LIMIT = 3;

/** How many friends the award podium considers (the player makes a 4th). */
export const FRIEND_AWARDS_LIMIT = 3;

/** How many boxes "Your favourite postbox" lists. */
export const FAVOURITE_POSTBOXES_LIMIT = 3;

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
  /** True when the build counted all the way to [unpackedCutoff]; false for
   *  an early (pre-cut-off) admin build. Set by the builder. */
  complete?: boolean;
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
  /** Claims per month, January first (12 entries). */
  monthCounts: number[];
  /** Points per weekday, Monday first (7 entries). */
  weekdayPoints: number[];
  busiestDay: { date: string; points: number; claims: number };
  /** The year's top days by claims (then points, then the earlier date),
   *  at most [BUSIEST_DAYS_LIMIT]. Unlike [busiestDay] (most points), this
   *  ranks by how many boxes were claimed. */
  busiestDays: Array<{ date: string; points: number; claims: number }>;
  rarestFind: {
    postboxId: string;
    monarch: string | null;
    points: number;
    dailyDate: string;
    reference: string | null;
    county: string | null;
  };
  /** Claims per cypher; plain/unknown boxes are counted under "NONE". */
  monarchCounts: Record<string, number>;
  /** Most distinct boxes claimed in one county; null when no claimed box
   *  carries a county. Ties go to the alphabetically first county. */
  topCounty: { name: string; uniquePostboxes: number } | null;
  countiesVisited: number;
  /** Distinct boxes per county the player claimed in (for the map). */
  countyBoxes: Record<string, number>;
  /** The boxes claimed on the most days (each at least 2), most first; ties
   *  go to the rarer cypher, then the postbox id. Empty when no box was
   *  claimed twice. */
  favouritePostboxes: Array<{
    claims: number;
    monarch: string | null;
    reference: string | null;
    county: string | null;
  }>;
  /** The player's next-best counties after [topCounty], by distinct boxes,
   *  limited to counties where at least one other player also claimed.
   *  Filled in by the builder once every player is known. */
  otherCounties: Array<{ name: string; uniquePostboxes: number; otherPlayers: number }>;
  /** Friends' best streaks of the year, longest first (uids only; the app
   *  looks the names up, so a deleted friend drops out). Filled in by the
   *  builder. */
  friendStreaks: Array<{ uid: string; days: number }>;
  /** The award podium's friends: the top friends by days out hunting (then
   *  boxes found), at most [FRIEND_AWARDS_LIMIT]. Uids only, like
   *  [friendStreaks]. Filled in by the builder. */
  friendAwards: Array<{ uid: string; daysActive: number; uniquePostboxes: number }>;
  /** Days the player scored the most points (or tied for the most), among
   *  their friends and among every player. A day counts only when someone
   *  else in that group also scored. Filled in by the builder. */
  topScorerDays: { friends: number; everyone: number };
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
  readonly weekdayPoints = new Array<number>(7).fill(0);
  readonly dayTotals = new Map<string, { points: number; claims: number }>();
  /** Claims (days) per postbox, with the box's cypher. */
  readonly boxClaims = new Map<string, { claims: number; monarch: string | null }>();
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
    this.weekdayPoints[isoWeekday(c.dailyDate) - 1] += points;
    const day = this.dayTotals.get(c.dailyDate) ?? { points: 0, claims: 0 };
    day.points += points;
    day.claims++;
    this.dayTotals.set(c.dailyDate, day);
    const box = this.boxClaims.get(c.postboxId) ?? { claims: 0, monarch: null };
    box.claims++;
    if (box.monarch === null && monarchKey !== "NONE") box.monarch = monarchKey;
    this.boxClaims.set(c.postboxId, box);

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

/** Distinct claimed boxes per county for one player (boxes without a county
 *  are left out). */
export function countyCounts(
  postboxes: Iterable<string>,
  meta: ReadonlyMap<string, PostboxMeta>,
): Map<string, number> {
  const perCounty = new Map<string, number>();
  for (const id of postboxes) {
    const county = meta.get(id)?.county;
    if (typeof county === "string" && county.length > 0) {
      perCounty.set(county, (perCounty.get(county) ?? 0) + 1);
    }
  }
  return perCounty;
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
  const busiestDays = sortedDays
    .map((date) => ({ date, ...acc.dayTotals.get(date)! }))
    .sort((a, b) => b.claims - a.claims || b.points - a.points || a.date.localeCompare(b.date))
    .slice(0, BUSIEST_DAYS_LIMIT)
    .map(({ date, points, claims }) => ({ date, points, claims }));

  const perCounty = countyCounts(acc.postboxes, meta);
  let topCounty: UnpackedStats["topCounty"] = null;
  for (const [name, n] of [...perCounty.entries()].sort(([a], [b]) => a.localeCompare(b))) {
    if (topCounty === null || n > topCounty.uniquePostboxes) topCounty = { name, uniquePostboxes: n };
  }

  const favouritePostboxes = [...acc.boxClaims.entries()]
    .filter(([, b]) => b.claims >= 2)
    .sort(([idA, a], [idB, b]) =>
      b.claims - a.claims || pointsForMonarch(b.monarch) - pointsForMonarch(a.monarch) || idA.localeCompare(idB))
    .slice(0, FAVOURITE_POSTBOXES_LIMIT)
    .map(([id, b]) => {
      const m = meta.get(id);
      return {
        claims: b.claims,
        monarch: b.monarch,
        reference: typeof m?.reference === "string" && m.reference.length > 0 ? m.reference : null,
        county: typeof m?.county === "string" && m.county.length > 0 ? m.county : null,
      };
    });

  const month = argMax(acc.monthCounts);
  const weekday = argMax(acc.weekdayCounts);
  const ref = meta.get(acc.rarest.postboxId)?.reference;
  const rarestCounty = meta.get(acc.rarest.postboxId)?.county;

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
    monthCounts: [...acc.monthCounts],
    weekdayPoints: [...acc.weekdayPoints],
    busiestDay,
    busiestDays,
    rarestFind: {
      ...acc.rarest,
      reference: typeof ref === "string" && ref.length > 0 ? ref : null,
      county: typeof rarestCounty === "string" && rarestCounty.length > 0 ? rarestCounty : null,
    },
    monarchCounts: { ...acc.monarchCounts },
    topCounty,
    countiesVisited: perCounty.size,
    countyBoxes: Object.fromEntries(perCounty),
    favouritePostboxes,
    otherCounties: [],
    friendStreaks: [],
    friendAwards: [],
    topScorerDays: { friends: 0, everyone: 0 },
    percentiles: { uniquePostboxes: 0, totalPoints: 0, longestStreak: 0 },
  };
}

/**
 * "Home turf"'s other counties: the player's best counties after [home], by
 * distinct boxes (ties alphabetical), keeping only counties where at least
 * one other player claimed too, so no listed area is the player's alone.
 * [playersByCounty] counts every player with a box in each county.
 */
export function otherCountiesFor(
  counts: ReadonlyMap<string, number>,
  home: string | null,
  playersByCounty: ReadonlyMap<string, number>,
  limit = OTHER_COUNTIES_LIMIT,
): UnpackedStats["otherCounties"] {
  return [...counts.entries()]
    .filter(([name]) => name !== home && (playersByCounty.get(name) ?? 0) >= 2)
    .sort(([a, n], [b, m]) => m - n || a.localeCompare(b))
    .slice(0, limit)
    .map(([name, n]) => ({ name, uniquePostboxes: n, otherPlayers: (playersByCounty.get(name) ?? 1) - 1 }));
}

/**
 * The friends shown on "Longest streak": each of [friends] (a `users` doc's
 * `friends` array, untrusted) who has a recap this year, with their best
 * streak, longest first (ties by uid, so the order is stable). The player
 * and duplicates are skipped.
 */
export function friendStreaksFor(
  uid: string,
  friends: unknown,
  streakByUid: ReadonlyMap<string, number>,
  limit = FRIEND_STREAKS_LIMIT,
): UnpackedStats["friendStreaks"] {
  if (!Array.isArray(friends)) return [];
  const seen = new Set<string>();
  const out: UnpackedStats["friendStreaks"] = [];
  for (const f of friends) {
    if (typeof f !== "string" || f === uid || seen.has(f)) continue;
    seen.add(f);
    const days = streakByUid.get(f);
    if (days !== undefined && days >= 1) out.push({ uid: f, days });
  }
  return out.sort((a, b) => b.days - a.days || a.uid.localeCompare(b.uid)).slice(0, limit);
}

/** The friend candidates for the award podium: each of [friends] with a
 *  recap this year, ranked by days out hunting, then boxes found, then uid.
 *  The player and duplicates are skipped. */
export function friendAwardsFor(
  uid: string,
  friends: unknown,
  statsByUid: ReadonlyMap<string, Pick<UnpackedStats, "daysActive" | "uniquePostboxes">>,
  limit = FRIEND_AWARDS_LIMIT,
): UnpackedStats["friendAwards"] {
  if (!Array.isArray(friends)) return [];
  const seen = new Set<string>();
  const out: UnpackedStats["friendAwards"] = [];
  for (const f of friends) {
    if (typeof f !== "string" || f === uid || seen.has(f)) continue;
    seen.add(f);
    const st = statsByUid.get(f);
    if (st && st.daysActive > 0) out.push({ uid: f, daysActive: st.daysActive, uniquePostboxes: st.uniquePostboxes });
  }
  return out
    .sort((a, b) => b.daysActive - a.daysActive || b.uniquePostboxes - a.uniquePostboxes || a.uid.localeCompare(b.uid))
    .slice(0, limit);
}

/** Per day: the best score, how many players had it, the best score below
 *  it, and how many players scored at all. Built once over every player. */
export interface DayLeaders {
  best: number;
  bestCount: number;
  second: number;
  scorers: number;
}

export function dayLeaders(
  players: Iterable<ReadonlyMap<string, { points: number }>>,
): Map<string, DayLeaders> {
  const out = new Map<string, DayLeaders>();
  for (const days of players) {
    for (const [date, { points }] of days) {
      if (points <= 0) continue;
      const d = out.get(date) ?? { best: 0, bestCount: 0, second: 0, scorers: 0 };
      d.scorers++;
      if (points > d.best) {
        d.second = d.best;
        d.best = points;
        d.bestCount = 1;
      } else if (points === d.best) {
        d.bestCount++;
      } else if (points > d.second) {
        d.second = points;
      }
      out.set(date, d);
    }
  }
  return out;
}

/** Days [mine] was top (or joint top) of every player, given [leaders]. A
 *  day counts only when another player also scored. */
export function topOfEveryoneDays(
  mine: ReadonlyMap<string, { points: number }>,
  leaders: ReadonlyMap<string, DayLeaders>,
): number {
  let n = 0;
  for (const [date, { points }] of mine) {
    const d = leaders.get(date);
    if (points <= 0 || !d || d.scorers < 2) continue;
    const othersBest = points === d.best ? (d.bestCount > 1 ? d.best : d.second) : d.best;
    if (points >= othersBest) n++;
  }
  return n;
}

/** Days [mine] was top (or joint top) of the player's [friends] (their
 *  per-day totals). A day counts only when a friend also scored. */
export function topOfFriendsDays(
  mine: ReadonlyMap<string, { points: number }>,
  friends: ReadonlyArray<ReadonlyMap<string, { points: number }>>,
): number {
  let n = 0;
  for (const [date, { points }] of mine) {
    if (points <= 0) continue;
    let best = 0;
    for (const f of friends) best = Math.max(best, f.get(date)?.points ?? 0);
    if (best > 0 && points >= best) n++;
  }
  return n;
}

/** Anonymous community-wide figures for the "Together" card. */
export interface CommunityHighlights {
  /** Counties with at least one claimed box. */
  countiesCovered: number;
  /** The rarest cypher anyone found (by its points value; ties go to the
   *  one with fewer boxes, then alphabetical), with how many distinct boxes
   *  of it were found. Null when only plain boxes were claimed. */
  rarestCypher: { monarch: string; boxes: number } | null;
  /** The best streak any player managed. Nobody is named. */
  longestStreak: number;
  /** The day with the most claims across everyone (earliest on a tie). */
  busiestDay: { date: string; claims: number } | null;
  /** Days with at least one claim, out of the days counted so far. */
  daysWithClaims: number;
  daysSoFar: number;
  /** Counties where at least two players claimed, alphabetical (for the
   *  map; a county with a single player is left off). Filled in by the
   *  builder. */
  sharedCounties: string[];
}

/** Inclusive count of days from 1 January of [year] to [through]. */
export function daysFromNewYear(year: number, through: string): number {
  const start = Date.UTC(year, 0, 1);
  const end = Date.parse(through + "T00:00:00Z");
  return Number.isFinite(end) && end >= start ? Math.round((end - start) / 86_400_000) + 1 : 0;
}

/**
 * Builds the community highlights. [boxMonarch] maps every claimed box to
 * its cypher (null for plain), [boxCounties] lists each claimed box's
 * county where known, and [dayClaims] counts everyone's claims per day.
 */
export function communityHighlights(input: {
  year: number;
  throughDate: string;
  stats: readonly UnpackedStats[];
  boxMonarch: ReadonlyMap<string, string | null>;
  boxCounties: Iterable<string>;
  dayClaims: ReadonlyMap<string, number>;
}): CommunityHighlights {
  const cypherBoxes = new Map<string, number>();
  for (const m of input.boxMonarch.values()) {
    if (m) cypherBoxes.set(m, (cypherBoxes.get(m) ?? 0) + 1);
  }
  let rarestCypher: CommunityHighlights["rarestCypher"] = null;
  for (const [monarch, boxes] of [...cypherBoxes.entries()].sort(([a], [b]) => a.localeCompare(b))) {
    const r = rarestCypher;
    const p = pointsForMonarch(monarch);
    if (r === null || p > pointsForMonarch(r.monarch) ||
      (p === pointsForMonarch(r.monarch) && boxes < r.boxes)) {
      rarestCypher = { monarch, boxes };
    }
  }

  let busiestDay: CommunityHighlights["busiestDay"] = null;
  for (const [date, claims] of [...input.dayClaims.entries()].sort(([a], [b]) => a.localeCompare(b))) {
    if (busiestDay === null || claims > busiestDay.claims) busiestDay = { date, claims };
  }

  return {
    countiesCovered: new Set(input.boxCounties).size,
    rarestCypher,
    longestStreak: input.stats.reduce((best, s) => Math.max(best, s.longestStreak.days), 0),
    busiestDay,
    daysWithClaims: input.dayClaims.size,
    daysSoFar: daysFromNewYear(input.year, input.throughDate),
    sharedCounties: [],
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

/** The last day the recap for [year] counts: Royal Mail's last recommended
 *  second-class posting date before Christmas (Friday 18 December in 2026).
 *  Check Royal Mail's published dates each year. */
export function unpackedCutoff(year: number): string {
  return `${year}-12-18`;
}

/** The recap for [year] opens the day after [unpackedCutoff] (19 December),
 *  once that day's claims are in, and closes on 15 January (London). */
export function unpackedWindow(year: number): UnpackedWindow {
  return { availableFrom: `${year}-12-19`, availableUntil: `${year + 1}-01-15` };
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

/** The recap year a build on [todayLondon] should prepare: the previous year
 *  in January (its window's tail, when a refresh can at last count all of
 *  December), otherwise the current year (December, plus the pre-launch
 *  admin builds in the autumn). */
export function recapYearToBuild(todayLondon: string): number {
  const year = parseInt(todayLondon.slice(0, 4), 10);
  return todayLondon.slice(5, 7) === "01" ? year - 1 : year;
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

/** Push body for the launch notification. (No character name: the guide is
 *  never named in user-facing copy.) */
export function launchNotifyBody(s: Pick<UnpackedStats, "year" | "uniquePostboxes">): string {
  const boxes = s.uniquePostboxes === 1 ? "1 postbox" : `${s.uniquePostboxes} postboxes`;
  return `You found ${boxes} in ${s.year}. Your year in postboxes is ready to unpack!`;
}

/**
 * True when [tokenData] (an `fcmTokens/{uid}` doc) shows the player's app can
 * open the recap. Only builds that ship the recap screen report an
 * `appVersion` to registerFcmToken, so its presence is the signal: an older
 * install would get "come and unpack it!" and find nothing to open.
 */
export function hasRecapCapableApp(tokenData: Record<string, unknown> | undefined): boolean {
  const v = tokenData?.appVersion;
  return typeof v === "string" && v.length > 0;
}
