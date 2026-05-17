/*
 * plan_route.ts — internal helper script.
 *
 * Given a start point, a destination, and a time budget (minutes), plot a
 * walking route from A to B that visits a high-scoring subset of postboxes
 * along the way without exceeding the budget.
 *
 * Run after `npm run build` (from functions/):
 *   node lib/scripts/plan_route.js \
 *     --start 51.5074,-0.1278 \
 *     --end   51.5155,-0.0922 \
 *     --minutes 60 \
 *     [--speed-kmh 4.5] \
 *     [--per-claim-seconds 60] \
 *     [--beam 50] \
 *     [--source firestore|file] \
 *     [--input postboxes.json] \
 *     [--project the-postbox-game]
 */

import * as fs from "fs";
import * as admin from "firebase-admin";
import * as geohash from "ngeohash";
import { pointsForMonarch, KNOWN_MONARCHS } from "../_getPoints";
import {
  type Point,
  type Candidate,
  type RouteStop,
  metresBetween,
  midpoint,
  filterToEllipse,
  beamSearchOrienteering,
  finaliseRoute,
} from "../_routePlanner";

type Options = {
  start: Point;
  end: Point;
  minutes: number;
  speedKmh: number;
  perClaimSeconds: number;
  beam: number;
  source: "firestore" | "file";
  inputPath?: string;
  projectId: string;
};

const DEFAULTS = {
  speedKmh: 4.5,
  perClaimSeconds: 60,
  beam: 50,
  source: "firestore" as const,
  projectId: "the-postbox-game",
};

// ---------- argv parsing ----------

function parseLatLng(raw: string, label: string): Point {
  const [latRaw, lngRaw] = raw.split(",").map((s) => s.trim());
  const lat = Number(latRaw);
  const lng = Number(lngRaw);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    throw new Error(`${label} must be "lat,lng" with finite numbers (got: "${raw}")`);
  }
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
    throw new Error(`${label} lat/lng out of range: ${lat},${lng}`);
  }
  return { lat, lng };
}

function parseArgs(argv: string[]): Options {
  const opts: Partial<Options> = {
    speedKmh: DEFAULTS.speedKmh,
    perClaimSeconds: DEFAULTS.perClaimSeconds,
    beam: DEFAULTS.beam,
    source: DEFAULTS.source,
    projectId: DEFAULTS.projectId,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const takeValue = () => {
      const v = argv[++i];
      if (v === undefined) throw new Error(`missing value for ${a}`);
      return v;
    };
    switch (a) {
      case "--start": opts.start = parseLatLng(takeValue(), "--start"); break;
      case "--end": opts.end = parseLatLng(takeValue(), "--end"); break;
      case "--minutes": opts.minutes = Number(takeValue()); break;
      case "--speed-kmh": opts.speedKmh = Number(takeValue()); break;
      case "--per-claim-seconds": opts.perClaimSeconds = Number(takeValue()); break;
      case "--beam": opts.beam = Number(takeValue()); break;
      case "--source": {
        const v = takeValue();
        if (v !== "firestore" && v !== "file") throw new Error(`--source must be firestore|file (got: ${v})`);
        opts.source = v;
        break;
      }
      case "--input": opts.inputPath = takeValue(); break;
      case "--project": opts.projectId = takeValue(); break;
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
  if (opts.minutes === undefined || !Number.isFinite(opts.minutes) || opts.minutes <= 0) {
    throw new Error("--minutes must be a positive number");
  }
  if (!Number.isFinite(opts.speedKmh!) || opts.speedKmh! <= 0) throw new Error("--speed-kmh must be positive");
  if (!Number.isFinite(opts.perClaimSeconds!) || opts.perClaimSeconds! < 0) throw new Error("--per-claim-seconds must be >= 0");
  if (!Number.isFinite(opts.beam!) || opts.beam! < 1) throw new Error("--beam must be >= 1");
  if (opts.source === "file" && !opts.inputPath) throw new Error("--source file requires --input <path>");
  return opts as Options;
}

function printUsage(): void {
  process.stderr.write(`Usage: node lib/scripts/plan_route.js \\
  --start LAT,LNG --end LAT,LNG --minutes N \\
  [--speed-kmh ${DEFAULTS.speedKmh}] [--per-claim-seconds ${DEFAULTS.perClaimSeconds}] \\
  [--beam ${DEFAULTS.beam}] [--source firestore|file] [--input postboxes.json] \\
  [--project ${DEFAULTS.projectId}]
`);
}

// ---------- geohash precision (mirrors _lookupPostboxes.setPrecision) ----------

function setPrecision(km: number): number {
  if (km <= 0.00477) return 9;
  if (km <= 0.0191) return 8;
  if (km <= 0.153) return 7;
  if (km <= 0.61) return 6;
  if (km <= 4.89) return 5;
  if (km <= 19.5) return 4;
  if (km <= 156) return 3;
  if (km <= 625) return 2;
  return 1;
}

function getLatLng(geopoint: unknown): Point | null {
  if (!geopoint || typeof geopoint !== "object") return null;
  const gp = geopoint as Record<string, unknown>;
  const lat = (gp._latitude ?? gp.latitude) as number | undefined;
  const lng = (gp._longitude ?? gp.longitude) as number | undefined;
  if (typeof lat !== "number" || typeof lng !== "number") return null;
  return { lat, lng };
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
      const pos = getLatLng(data.geopoint);
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

function loadFromFile(path: string): Candidate[] {
  const raw = fs.readFileSync(path, "utf-8");
  const parsed = JSON.parse(raw);
  if (!Array.isArray(parsed)) throw new Error(`${path}: expected a JSON array of postboxes`);
  const out: Candidate[] = [];
  let unknownWarned = 0;
  for (const r of parsed as Record<string, unknown>[]) {
    const id = typeof r.id === "string" ? r.id : null;
    const lat = typeof r.lat === "number" ? r.lat : null;
    const lng = typeof r.lng === "number" ? r.lng : null;
    if (!id || lat === null || lng === null) continue;
    const monarch = typeof r.monarch === "string" ? r.monarch : null;
    if (monarch && !KNOWN_MONARCHS.includes(monarch) && unknownWarned < 5) {
      process.stderr.write(`warning: unknown monarch "${monarch}" on ${id} — scored at 2 pts\n`);
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

// ---------- formatting ----------

function fmtMin(s: number): string {
  return (s / 60).toFixed(1);
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

function pad(s: string, w: number, align: "l" | "r" = "l"): string {
  if (s.length >= w) return s;
  return align === "l" ? s + " ".repeat(w - s.length) : " ".repeat(w - s.length) + s;
}

function printReport(
  opts: Options,
  totalCandidates: number,
  retainedCandidates: number,
  directMetres: number,
  result: ReturnType<typeof finaliseRoute>,
): void {
  const { state, closingMetres, totalMetres, totalSeconds } = result;
  const budgetSeconds = opts.minutes * 60;
  const speedMps = (opts.speedKmh * 1000) / 3600;

  process.stdout.write(
    `Route plan — ${opts.minutes} min budget @ ${opts.speedKmh} km/h ` +
    `(${retainedCandidates} candidates retained out of ${totalCandidates})\n`,
  );
  process.stdout.write(`Start:       ${opts.start.lat.toFixed(5)}, ${opts.start.lng.toFixed(5)}\n`);
  process.stdout.write(`Destination: ${opts.end.lat.toFixed(5)}, ${opts.end.lng.toFixed(5)}\n`);
  process.stdout.write(`Direct distance: ${(directMetres / 1000).toFixed(2)} km (≈ ${fmtMin(directMetres / speedMps)} min walking)\n\n`);

  const row = (n: string, monarch: string, pts: string, ref: string, leg: string, cum: string, url: string): string =>
    `${pad(n, 4, "l")}${pad(monarch, 9, "l")}${pad(pts, 5, "r")}  ${pad(ref, 16, "l")}${pad(leg, 8, "r")}${pad(cum, 10, "r")}  ${url}\n`;

  process.stdout.write(row("#", "monarch", "pts", "reference", "leg(m)", "cum(min)", "Maps URL"));
  process.stdout.write(row("--", "-------", "---", "---------------", "------", "--------", "----------"));

  state.route.forEach((stop, i) => {
    process.stdout.write(row(
      `${i + 1}.`,
      stop.postbox.monarch ?? "(none)",
      String(stop.postbox.points),
      stop.postbox.reference ?? "-",
      String(Math.round(stop.legMeters)),
      fmtMin(stop.cumSeconds),
      mapsUrl({ lat: stop.postbox.lat, lng: stop.postbox.lng }),
    ));
  });

  process.stdout.write(row("", "", "", "-> destination", String(Math.round(closingMetres)), fmtMin(totalSeconds), ""));
  process.stdout.write("\n");

  const slack = budgetSeconds - totalSeconds;
  const slackText = slack >= 0
    ? `under budget by ${fmtMin(slack)} min`
    : `OVER budget by ${fmtMin(-slack)} min`;
  process.stdout.write(
    `Total: ${state.score} points  ${(totalMetres / 1000).toFixed(2)} km walked  ${fmtMin(totalSeconds)} min (${slackText})\n\n`,
  );

  process.stdout.write(`Full route Google Maps:\n${fullRouteUrl(opts.start, opts.end, state.route)}\n`);
}

// ---------- entry point ----------

async function main(): Promise<void> {
  const opts = parseArgs(process.argv.slice(2));

  const speedMps = (opts.speedKmh * 1000) / 3600;
  const budgetSeconds = opts.minutes * 60;
  const budgetMetres = speedMps * budgetSeconds;
  const directMetres = metresBetween(opts.start, opts.end);

  if (directMetres > budgetMetres) {
    process.stderr.write(
      `Destination unreachable in budget: direct A->B = ${(directMetres / 1000).toFixed(2)} km, ` +
      `budget covers only ${(budgetMetres / 1000).toFixed(2)} km at ${opts.speedKmh} km/h.\n`,
    );
    process.exit(2);
  }

  const centre = midpoint(opts.start, opts.end);
  const radiusMetres = budgetMetres / 2;

  const allCandidates = opts.source === "firestore"
    ? await loadFromFirestore(centre, radiusMetres, opts.projectId)
    : loadFromFile(opts.inputPath!);

  process.stderr.write(`Loaded ${allCandidates.length} postboxes from ${opts.source}.\n`);

  const inEllipse = filterToEllipse(allCandidates, opts.start, opts.end, budgetMetres);
  process.stderr.write(`Filtered to ${inEllipse.length} candidates inside the time ellipse.\n`);

  const bestState = beamSearchOrienteering(
    opts.start,
    opts.end,
    inEllipse,
    budgetSeconds,
    speedMps,
    opts.perClaimSeconds,
    opts.beam,
  );

  const result = finaliseRoute(bestState, opts.end, speedMps);
  printReport(opts, allCandidates.length, inEllipse.length, directMetres, result);
}

main().catch((err) => {
  process.stderr.write(`Error: ${err instanceof Error ? err.message : String(err)}\n`);
  process.exit(1);
});
