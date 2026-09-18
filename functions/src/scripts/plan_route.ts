/*
 * plan_route.ts — internal helper script.
 *
 * Given a start point, a destination, and a budget — either a time budget in
 * minutes or a walking-distance budget in km — plot a walking route from A to
 * B that visits a high-scoring subset of postboxes along the way without
 * exceeding the budget.
 *
 * Run after `npm run build` (from functions/):
 *   node lib/scripts/plan_route.js \
 *     --start 51.5074,-0.1278 \
 *     --end   "51.5155, -0.0922" \
 *     --minutes 60 | --km 5 \
 *     [--speed-kmh 4.5] \
 *     [--per-claim-seconds 60] \
 *     [--beam 50] \
 *     [--source firestore|file] \
 *     [--input postboxes.json] \
 *     [--project the-postbox-game] \
 *     [--avoid "BS37 614,osm_271462"] [--avoid ...] \
 *     [--alternatives 1]
 *
 * Coordinates may be "lat,lng", "lat, lng" (a Google Maps paste — quoted or
 * not) or "lat lng". --minutes is a TOTAL time budget (walking + per-claim
 * dwell); --km is a TOTAL walking-distance budget (dwell is shown in the ETA
 * but never shortens the route). --input accepts either a flat JSON array of
 * {id, lat, lng, monarch?, reference?} or a raw Overpass export
 * ({ elements: [{ type: "node", id, lat, lon, tags }] }). --avoid skips
 * postboxes by id or reference (repeatable, comma-separated; matching is
 * case/space-insensitive and a single part of an "A;B" multi-reference counts).
 * --alternatives N prints the best route plus up to N-1 alternatives drawn
 * from the same search, each sharing at most half its stops with the routes
 * above it where the candidate pool allows.
 */

import * as fs from "fs";
import * as admin from "firebase-admin";
import * as geohash from "ngeohash";
import { pointsForMonarch, KNOWN_MONARCHS } from "../_getPoints";
import { setPrecision, getLatLng } from "../_geo";
import {
  type Point,
  type Candidate,
  type RouteStop,
  metresBetween,
  midpoint,
  filterToEllipse,
  beamSearchOrienteering,
  finaliseRoute,
  selectAlternatives,
  type SearchState,
} from "../_routePlanner";

export type Budget =
  | { kind: "minutes"; minutes: number }
  | { kind: "km"; km: number };

export type Options = {
  start: Point;
  end: Point;
  budget: Budget;
  speedKmh: number;
  perClaimSeconds: number;
  beam: number;
  source: "firestore" | "file";
  inputPath?: string;
  projectId: string;
  avoid: string[];
  alternatives: number;
};

const DEFAULTS = {
  speedKmh: 4.5,
  perClaimSeconds: 60,
  beam: 50,
  alternatives: 1,
  source: "firestore" as const,
  projectId: "the-postbox-game",
};

function kmhToMps(kmh: number): number {
  return (kmh * 1000) / 3600;
}

// ---------- argv parsing ----------

/** Split a coordinate string on commas and/or whitespace, dropping empties. */
function coordParts(raw: string): string[] {
  return raw.split(/[\s,]+/).filter((s) => s.length > 0);
}

/**
 * Parse "lat,lng", "lat, lng" or "lat lng". Requires exactly two finite
 * numbers — a trailing comma ("51.5,") is an error, not lng = 0.
 */
export function parseLatLng(raw: string, label: string): Point {
  const parts = coordParts(raw);
  if (parts.length === 2) {
    const lat = Number(parts[0]);
    const lng = Number(parts[1]);
    if (Number.isFinite(lat) && Number.isFinite(lng)) {
      if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
        throw new Error(`${label} lat/lng out of range: ${lat},${lng}`);
      }
      return { lat, lng };
    }
  }
  throw new Error(`${label} must be "lat,lng", "lat, lng" or "lat lng" with two finite numbers (got: "${raw}")`);
}

export function parseArgs(argv: string[]): Options {
  const opts: Partial<Options> = {
    speedKmh: DEFAULTS.speedKmh,
    perClaimSeconds: DEFAULTS.perClaimSeconds,
    beam: DEFAULTS.beam,
    source: DEFAULTS.source,
    projectId: DEFAULTS.projectId,
    avoid: [],
    alternatives: DEFAULTS.alternatives,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const takeValue = () => {
      const v = argv[++i];
      if (v === undefined) throw new Error(`missing value for ${a}`);
      return v;
    };
    // An unquoted "lat, lng" reaches us shell-split into "lat," + "lng" (or
    // "lat" + "," + "lng"): borrow following tokens until we hold two numeric
    // parts, never crossing into the next --flag. A negative longitude starts
    // with a single "-", so the "--" guard cannot mistake it for a flag.
    const takeCoord = (label: string): Point => {
      let raw = takeValue();
      while (coordParts(raw).length < 2 && argv[i + 1] !== undefined && !argv[i + 1].startsWith("--")) {
        raw = `${raw} ${argv[++i]}`;
      }
      return parseLatLng(raw, label);
    };
    const setBudget = (b: Budget) => {
      if (opts.budget) throw new Error("--minutes and --km are mutually exclusive: give exactly one budget");
      opts.budget = b;
    };
    switch (a) {
      case "--start": opts.start = takeCoord("--start"); break;
      case "--end": opts.end = takeCoord("--end"); break;
      case "--minutes": setBudget({ kind: "minutes", minutes: Number(takeValue()) }); break;
      case "--km": setBudget({ kind: "km", km: Number(takeValue()) }); break;
      case "--speed-kmh": opts.speedKmh = Number(takeValue()); break;
      case "--per-claim-seconds": opts.perClaimSeconds = Number(takeValue()); break;
      case "--beam": opts.beam = Number(takeValue()); break;
      case "--alternatives": opts.alternatives = Number(takeValue()); break;
      case "--source": {
        const v = takeValue();
        if (v !== "firestore" && v !== "file") throw new Error(`--source must be firestore|file (got: ${v})`);
        opts.source = v;
        break;
      }
      case "--input": opts.inputPath = takeValue(); break;
      case "--project": opts.projectId = takeValue(); break;
      case "--avoid":
        opts.avoid!.push(...takeValue().split(",").map((s) => s.trim()).filter((s) => s.length > 0));
        break;
      case "--help":
      case "-h":
        printUsage();
        process.exit(0);
        break;
      default:
        throw new Error(`unknown flag: ${a}`);
    }
  }
  if (!opts.start) throw new Error("--start is required (e.g. --start 51.5074,-0.1278)");
  if (!opts.end) throw new Error("--end is required (e.g. --end 51.5155,-0.0922)");
  if (!opts.budget) throw new Error("a budget is required: exactly one of --minutes N or --km D");
  if (opts.budget.kind === "minutes" && !(Number.isFinite(opts.budget.minutes) && opts.budget.minutes > 0)) {
    throw new Error("--minutes must be a positive number");
  }
  if (opts.budget.kind === "km" && !(Number.isFinite(opts.budget.km) && opts.budget.km > 0)) {
    throw new Error("--km must be a positive number");
  }
  if (!Number.isFinite(opts.speedKmh!) || opts.speedKmh! <= 0) throw new Error("--speed-kmh must be positive");
  if (!Number.isFinite(opts.perClaimSeconds!) || opts.perClaimSeconds! < 0) throw new Error("--per-claim-seconds must be >= 0");
  if (!Number.isFinite(opts.beam!) || opts.beam! < 1) throw new Error("--beam must be >= 1");
  if (!Number.isInteger(opts.alternatives) || opts.alternatives! < 1) throw new Error("--alternatives must be a whole number >= 1");
  if (opts.source === "file" && !opts.inputPath) throw new Error("--source file requires --input <path>");
  return opts as Options;
}

/**
 * Turn the user's budget into what the planner needs.
 *
 * A minutes budget is total time, so per-claim dwell is charged inside the
 * search exactly as before. A km budget is pure walking distance: the search
 * runs with ZERO dwell (otherwise each stop would silently shorten the route
 * by ~speed × dwell) and the dwell is added back only when reporting the ETA.
 */
export function resolveBudget(
  budget: Budget,
  speedKmh: number,
  perClaimSeconds: number,
): { budgetSeconds: number; budgetMetres: number; searchPerClaimSeconds: number } {
  const speedMps = kmhToMps(speedKmh);
  if (budget.kind === "minutes") {
    const budgetSeconds = budget.minutes * 60;
    return { budgetSeconds, budgetMetres: speedMps * budgetSeconds, searchPerClaimSeconds: perClaimSeconds };
  }
  const budgetMetres = budget.km * 1000;
  return { budgetSeconds: budgetMetres / speedMps, budgetMetres, searchPerClaimSeconds: 0 };
}

/** Case- and whitespace-insensitive key for ids and references. */
function normaliseKey(s: string): string {
  return s.trim().toUpperCase().replace(/\s+/g, " ");
}

/**
 * Drop candidates named by --avoid. An entry matches a postbox's id or its
 * reference; a single part of an "A;B" multi-reference counts. Entries that
 * matched nothing are returned so a typo isn't silently ignored.
 */
export function applyAvoidList(
  candidates: Candidate[],
  avoid: string[],
): { kept: Candidate[]; removed: Candidate[]; unmatched: string[] } {
  const wanted = new Map<string, string>(); // normalised key -> entry as typed
  for (const entry of avoid) {
    const key = normaliseKey(entry);
    if (key && !wanted.has(key)) wanted.set(key, entry);
  }
  if (wanted.size === 0) return { kept: candidates, removed: [], unmatched: [] };

  const hit = new Set<string>();
  const kept: Candidate[] = [];
  const removed: Candidate[] = [];
  for (const c of candidates) {
    const keys = [normaliseKey(c.id), ...(c.reference ? c.reference.split(";").map(normaliseKey) : [])];
    const matches = keys.filter((k) => wanted.has(k));
    if (matches.length === 0) {
      kept.push(c);
      continue;
    }
    matches.forEach((k) => hit.add(k));
    removed.push(c);
  }
  const unmatched = [...wanted].filter(([key]) => !hit.has(key)).map(([, entry]) => entry);
  return { kept, removed, unmatched };
}

function printUsage(): void {
  process.stderr.write(`Usage: node lib/scripts/plan_route.js \\
  --start LAT,LNG --end LAT,LNG (--minutes N | --km D) \\
  [--speed-kmh ${DEFAULTS.speedKmh}] [--per-claim-seconds ${DEFAULTS.perClaimSeconds}] \\
  [--beam ${DEFAULTS.beam}] [--alternatives ${DEFAULTS.alternatives}] [--source firestore|file] [--input postboxes.json] \\
  [--project ${DEFAULTS.projectId}] [--avoid ID|REF[,ID|REF...]]...

  Coordinates accept "lat,lng", "lat, lng" (Google Maps paste) or "lat lng".
  --minutes is a total time budget; --km is a total walking-distance budget.
  --input takes a flat {id,lat,lng,monarch} array or a raw Overpass export.
  --avoid skips postboxes by id (osm_...) or reference, as printed; repeatable.
  --alternatives N also prints up to N-1 different routes from the same search.
`);
}

// ---------- data loaders ----------

async function loadFromFirestore(centre: Point, radiusMetres: number, projectId: string): Promise<Candidate[]> {
  if (!admin.apps.length) admin.initializeApp({ projectId });
  const db = admin.firestore();

  const precision = setPrecision(radiusMetres / 1000);
  const centreHash = geohash.encode(centre.lat, centre.lng, precision);
  const cells = [centreHash, ...geohash.neighbors(centreHash)];

  const snapshots = await Promise.all(
    cells.map((prefix) => db.collection("postbox").orderBy("geohash").startAt(prefix).endAt(prefix + "\uf8ff").get()),
  );

  const seen = new Set<string>();
  const candidates: Candidate[] = [];
  for (const snap of snapshots) {
    for (const doc of snap.docs) {
      if (seen.has(doc.id)) continue;
      seen.add(doc.id);
      const data = doc.data() as Record<string, unknown>;
      const pos = getLatLng(data.geopoint as Parameters<typeof getLatLng>[0]);
      if (!pos) continue;
      const monarch = typeof data.monarch === "string" ? data.monarch : null;
      candidates.push({
        id: doc.id,
        lat: pos.lat,
        lng: pos.lng,
        monarch,
        points: pointsForMonarch(monarch),
        reference: typeof data.reference === "string" ? data.reference : undefined,
        county: typeof data.county === "string" ? data.county : undefined,
      });
    }
  }
  return candidates;
}

type Warn = (msg: string) => void;
const stderrWarn: Warn = (msg) => process.stderr.write(`${msg}\n`);

/** Flat format: [{ id, lat, lng, monarch?, reference?, county? }]. */
function candidatesFromFlat(rows: unknown[], warn: Warn): Candidate[] {
  const out: Candidate[] = [];
  let unknownWarned = 0;
  for (const r of rows as Record<string, unknown>[]) {
    const id = typeof r.id === "string" ? r.id : null;
    const lat = typeof r.lat === "number" ? r.lat : null;
    const lng = typeof r.lng === "number" ? r.lng : null;
    if (!id || lat === null || lng === null) continue;
    const monarch = typeof r.monarch === "string" ? r.monarch : null;
    if (monarch && !KNOWN_MONARCHS.includes(monarch) && unknownWarned < 5) {
      warn(`warning: unknown monarch "${monarch}" on ${id} — scored at 2 pts`);
      unknownWarned++;
    }
    out.push({
      id,
      lat,
      lng,
      monarch,
      points: pointsForMonarch(monarch),
      reference: typeof r.reference === "string" ? r.reference : undefined,
      county: typeof r.county === "string" ? r.county : undefined,
    });
  }
  return out;
}

/**
 * Raw Overpass export: { elements: [{ type: "node", id, lat, lon, tags }] }.
 * Mirrors buildDoc() in import_postboxes.js so the CLI scores a box exactly
 * as Firestore would: ids are `osm_<id>`, the royal_cypher tag is upper-cased
 * and kept only if the game recognises it (anything else scores the default).
 */
function candidatesFromOverpass(elements: unknown[]): Candidate[] {
  const out: Candidate[] = [];
  for (const e of elements as Array<Record<string, unknown> | null>) {
    if (!e || e.type !== "node" || typeof e.lat !== "number" || typeof e.lon !== "number") continue;
    if (typeof e.id !== "number" && typeof e.id !== "string") continue;
    const tags = (e.tags ?? {}) as Record<string, unknown>;
    const rawCypher = typeof tags.royal_cypher === "string" ? tags.royal_cypher.toUpperCase().trim() : "";
    const monarch = rawCypher && KNOWN_MONARCHS.includes(rawCypher) ? rawCypher : null;
    out.push({
      id: `osm_${e.id}`,
      lat: e.lat,
      lng: e.lon,
      monarch,
      points: pointsForMonarch(monarch),
      reference: typeof tags.ref === "string" && tags.ref ? tags.ref : undefined,
    });
  }
  return out;
}

/** Accept either the flat array format or a raw Overpass export. */
export function candidatesFromJson(parsed: unknown, warn: Warn = stderrWarn): Candidate[] {
  if (Array.isArray(parsed)) return candidatesFromFlat(parsed, warn);
  const elements = (parsed as { elements?: unknown } | null)?.elements;
  if (Array.isArray(elements)) return candidatesFromOverpass(elements);
  throw new Error("expected a JSON array of postboxes or a raw Overpass export ({ elements: [...] })");
}

function loadFromFile(path: string): Candidate[] {
  const parsed: unknown = JSON.parse(fs.readFileSync(path, "utf-8"));
  try {
    return candidatesFromJson(parsed);
  } catch (err) {
    throw new Error(`${path}: ${err instanceof Error ? err.message : String(err)}`);
  }
}

// ---------- formatting ----------

function fmtMin(s: number): string {
  return (s / 60).toFixed(1);
}

function fmtKm(m: number): string {
  return (m / 1000).toFixed(2);
}

function mapsUrl(p: Point): string {
  return `https://www.google.com/maps/?q=${p.lat.toFixed(6)},${p.lng.toFixed(6)}`;
}

function fullRouteUrl(start: Point, end: Point, stops: RouteStop[]): string {
  const waypoints = stops
    .map((s) => `${s.postbox.lat.toFixed(6)},${s.postbox.lng.toFixed(6)}`)
    .join("|");
  const origin = `${start.lat.toFixed(6)},${start.lng.toFixed(6)}`;
  const dest = `${end.lat.toFixed(6)},${end.lng.toFixed(6)}`;
  const wp = waypoints ? `&waypoints=${encodeURIComponent(waypoints)}` : "";
  return `https://www.google.com/maps/dir/?api=1&origin=${origin}&destination=${dest}${wp}&travelmode=walking`;
}

/**
 * Fixed-width cell. A left-aligned cell that overflows its column still gets
 * one trailing space so it can't run into the next column (e.g. a long
 * "A;B" multi-reference next to the id column).
 */
export function pad(s: string, w: number, align: "l" | "r" = "l"): string {
  if (align === "l") return s + " ".repeat(Math.max(1, w - s.length));
  return s.length >= w ? s : " ".repeat(w - s.length) + s;
}

type RouteResult = ReturnType<typeof finaliseRoute>;

function sharedStops(a: SearchState, b: SearchState): number {
  let n = 0;
  for (const id of a.visited) if (b.visited.has(id)) n++;
  return n;
}

function printReport(
  opts: Options,
  totalCandidates: number,
  retainedCandidates: number,
  directMetres: number,
  results: RouteResult[],
): void {
  const speedMps = kmhToMps(opts.speedKmh);
  const { budgetSeconds, budgetMetres, searchPerClaimSeconds } = resolveBudget(opts.budget, opts.speedKmh, opts.perClaimSeconds);
  // In km mode the search ran with zero dwell; add it back for the ETA figures.
  const dwellPerStop = opts.perClaimSeconds - searchPerClaimSeconds;

  const budgetText = opts.budget.kind === "km"
    ? `${opts.budget.km.toFixed(2)} km budget @ ${opts.speedKmh} km/h (≈ ${fmtMin(budgetSeconds)} min walking)`
    : `${opts.budget.minutes} min budget @ ${opts.speedKmh} km/h`;
  process.stdout.write(
    `Route plan — ${budgetText} (${retainedCandidates} candidates retained out of ${totalCandidates})\n`,
  );
  process.stdout.write(`Start:       ${opts.start.lat.toFixed(5)}, ${opts.start.lng.toFixed(5)}\n`);
  process.stdout.write(`Destination: ${opts.end.lat.toFixed(5)}, ${opts.end.lng.toFixed(5)}\n`);
  process.stdout.write(`Direct distance: ${fmtKm(directMetres)} km (≈ ${fmtMin(directMetres / speedMps)} min walking)\n\n`);

  results.forEach((result, r) => printRoute(opts, results, r, dwellPerStop, budgetSeconds, budgetMetres));
}

function printRoute(
  opts: Options,
  results: RouteResult[],
  r: number,
  dwellPerStop: number,
  budgetSeconds: number,
  budgetMetres: number,
): void {
  const { state, closingMetres, totalMetres, totalSeconds } = results[r];
  const stops = state.route.length;

  if (results.length > 1) {
    const note = r === 0 ? "" : ` (shares ${sharedStops(state, results[0].state)} of ${stops} stops with route 1)`;
    process.stdout.write(`=== Route ${r + 1} of ${results.length}${note} ===\n`);
  }

  const row = (n: string, monarch: string, pts: string, ref: string, id: string, leg: string, cum: string, url: string): string =>
    `${pad(n, 4, "l")}${pad(monarch, 9, "l")}${pad(pts, 5, "r")}  ${pad(ref, 16, "l")}${pad(id, 17, "l")}${pad(leg, 8, "r")}${pad(cum, 10, "r")}  ${url}\n`;

  process.stdout.write(row("#", "monarch", "pts", "reference", "id", "leg(m)", "cum(min)", "Maps URL"));
  process.stdout.write(row("--", "-------", "---", "---------------", "----------------", "------", "--------", "----------"));

  state.route.forEach((stop, i) => {
    process.stdout.write(row(
      `${i + 1}.`,
      stop.postbox.monarch ?? "(none)",
      String(stop.postbox.points),
      stop.postbox.reference ?? "-",
      stop.postbox.id,
      String(Math.round(stop.legMeters)),
      fmtMin(stop.cumSeconds + (i + 1) * dwellPerStop),
      mapsUrl({ lat: stop.postbox.lat, lng: stop.postbox.lng }),
    ));
  });

  const etaSeconds = totalSeconds + stops * dwellPerStop;
  process.stdout.write(row("", "", "", "-> destination", "", String(Math.round(closingMetres)), fmtMin(etaSeconds), ""));
  process.stdout.write("\n");

  let slackText: string;
  if (opts.budget.kind === "km") {
    const slackMetres = budgetMetres - totalMetres;
    slackText = slackMetres >= 0
      ? `under budget by ${fmtKm(slackMetres)} km`
      : `OVER budget by ${fmtKm(-slackMetres)} km`;
  } else {
    const slack = budgetSeconds - totalSeconds;
    slackText = slack >= 0
      ? `under budget by ${fmtMin(slack)} min`
      : `OVER budget by ${fmtMin(-slack)} min`;
  }
  const dwellNote = dwellPerStop > 0 && stops > 0 ? ` incl. ${stops} × ${opts.perClaimSeconds} s at stops` : "";
  process.stdout.write(
    `Total: ${state.score} points  ${fmtKm(totalMetres)} km walked  ${fmtMin(etaSeconds)} min${dwellNote} (${slackText})\n\n`,
  );

  process.stdout.write(`Full route Google Maps:\n${fullRouteUrl(opts.start, opts.end, state.route)}\n`);
  if (r < results.length - 1) process.stdout.write("\n");
}

// ---------- entry point ----------

async function main(): Promise<void> {
  const opts = parseArgs(process.argv.slice(2));

  const speedMps = kmhToMps(opts.speedKmh);
  const { budgetSeconds, budgetMetres, searchPerClaimSeconds } = resolveBudget(opts.budget, opts.speedKmh, opts.perClaimSeconds);
  const directMetres = metresBetween(opts.start, opts.end);

  if (directMetres > budgetMetres) {
    const budgetText = opts.budget.kind === "km"
      ? `budget is ${fmtKm(budgetMetres)} km`
      : `budget covers only ${fmtKm(budgetMetres)} km at ${opts.speedKmh} km/h`;
    process.stderr.write(`Destination unreachable in budget: direct A->B = ${fmtKm(directMetres)} km, ${budgetText}.\n`);
    process.exit(2);
  }

  const centre = midpoint(opts.start, opts.end);
  const radiusMetres = budgetMetres / 2;

  const allCandidates = opts.source === "firestore"
    ? await loadFromFirestore(centre, radiusMetres, opts.projectId)
    : loadFromFile(opts.inputPath!);

  process.stderr.write(`Loaded ${allCandidates.length} postboxes from ${opts.source}.\n`);

  const { kept: candidates, removed, unmatched } = applyAvoidList(allCandidates, opts.avoid);
  if (opts.avoid.length > 0) {
    process.stderr.write(`Avoiding ${removed.length} postbox${removed.length === 1 ? "" : "es"} via --avoid.\n`);
    if (unmatched.length > 0) {
      process.stderr.write(`warning: --avoid entries matched nothing: ${unmatched.join(", ")}\n`);
    }
  }

  const inEllipse = filterToEllipse(candidates, opts.start, opts.end, budgetMetres);
  process.stderr.write(`Filtered to ${inEllipse.length} candidates inside the budget ellipse.\n`);

  // With --alternatives > 1, keep every feasible state the search generated
  // and pick a diverse top-N from that pool; the best route is always first.
  const explored: SearchState[] = [];
  const bestState = beamSearchOrienteering(
    opts.start,
    opts.end,
    inEllipse,
    budgetSeconds,
    speedMps,
    searchPerClaimSeconds,
    opts.beam,
    opts.alternatives > 1 ? (s) => explored.push(s) : undefined,
  );
  const routes = opts.alternatives > 1
    ? selectAlternatives([bestState, ...explored], opts.alternatives)
    : [bestState];
  if (routes.length < opts.alternatives) {
    process.stderr.write(`Only ${routes.length} distinct route${routes.length === 1 ? "" : "s"} found (asked for ${opts.alternatives}).\n`);
  }

  const results = routes.map((s) => finaliseRoute(s, opts.end, speedMps));
  printReport(opts, allCandidates.length, inEllipse.length, directMetres, results);
}

// Only run when executed directly, so the pure helpers above can be imported
// by the test suite without kicking off a plan.
if (require.main === module) {
  main().catch((err) => {
    process.stderr.write(`Error: ${err instanceof Error ? err.message : String(err)}\n`);
    process.exit(1);
  });
}
