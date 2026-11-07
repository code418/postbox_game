// Pure route-matching geometry for workout claims (Health Connect today; any
// other route source — HealthKit, Strava, the Google Health API — tomorrow).
//
// Given a recorded GPS route and the postboxes near it, work out which boxes
// the route passed within the claim radius, WHEN, and from which point on the
// route. That point (the "anchor") is what the claim is later scored at, so
// the acceptance test here deliberately uses the exact comparison the claim
// path's lookupPostboxes makes (geolib.getDistance(anchor, box) <= radius):
// a box this module accepts is guaranteed to be found again at claim time.
//
// No firebase-admin and no adminInit (same discipline as _routePlanner.ts), so
// every function here is unit-testable without an emulator and reusable by a
// future server-side (webhook) route source.

import { createHash } from "crypto";
import * as geolib from "geolib";
import * as geohash from "ngeohash";
import { getLondonDayOf } from "./_dateUtils";

/** One timestamped fix on a recorded route. */
export interface RoutePoint {
  lat: number;
  lng: number;
  tMs: number;
}

/** A postbox near the route (from the geohash cell fetch). */
export interface RouteBox {
  id: string;
  lat: number;
  lng: number;
  monarch?: string;
}

/** The closest pass of the route by one box on one London day. */
export interface RoutePass {
  boxId: string;
  monarch?: string;
  boxLat: number;
  boxLng: number;
  /** The projected point on the route closest to the box (the claim anchor). */
  point: { lat: number; lng: number };
  /** Interpolated time the route was at [point]. */
  passedAtMs: number;
  /** London day of [passedAtMs] (YYYY-MM-DD) — the day the claim belongs to. */
  claimDate: string;
  /** geolib distance (integer metres) from [point] to the box. */
  distanceM: number;
}

/** Boxes claimable together with one quiz: all within the radius of [anchor]. */
export interface CandidateGroup {
  boxIds: string[];
  monarchs: Array<string | undefined>;
  anchor: { lat: number; lng: number };
  passedAtMs: number;
  claimDate: string;
}

/** Tunables for validateRoute. */
export interface RouteLimits {
  /** How long after a box is passed it stays claimable. */
  graceMs: number;
  maxPoints: number;
  /** Total route length cap. */
  maxRouteM: number;
  maxDurationMs: number;
  /** Segments implying more than this speed are excluded from matching. */
  maxSegmentMps: number;
  /** Fraction of the route's distance that may be speed-masked before the
   *  whole route is judged implausible. */
  maxMaskedFraction: number;
  /** A segment longer than gapMinM whose time gap exceeds this is a GPS
   *  dropout chord: the straight line between the fixes is not where the
   *  runner went, so it is excluded from matching (without counting as
   *  implausible). */
  maxGapMs: number;
  gapMinM: number;
  /** Tolerance for points just outside the session's start/end. */
  timeSlackMs: number;
  /** Tolerance for a session ending slightly in the future (clock skew). */
  futureSlackMs: number;
}

export const MAX_ROUTE_POINTS = 5000;
export const MAX_ROUTE_M = 60_000;
export const MAX_SESSION_MS = 12 * 60 * 60 * 1000;
/** 30 km/h — comfortably above a sprint, well below a car. */
export const MAX_SEGMENT_MPS = 30_000 / 3600;
export const MAX_MASKED_FRACTION = 0.25;
export const MAX_GAP_MS = 180_000;
export const GAP_MIN_M = 50;
/** Cap on geohash cells one route may cover (bounds Firestore reads). */
export const MAX_ROUTE_CELLS = 1500;
/** Sub-segment length used when computing covering cells. */
export const CELL_PIECE_M = 150;
/** Boxes passed within this long of each other (and within the radius of the
 *  group anchor) share one quiz, mirroring live play's one-quiz-per-scan. */
export const GROUP_MAX_DT_MS = 120_000;

/** Geohash precision whose cells comfortably contain a 30 m buffer (the same
 *  precision lookupPostboxes queries at for a 30 m radius). */
export const ROUTE_CELL_PRECISION = 7;

/** Rough British Isles bounds (incl. Channel Islands, Scilly, Shetland). The
 *  postbox dataset is UK-only, so a route outside this can match nothing. */
export const BRITISH_ISLES = { minLat: 49, maxLat: 61, minLng: -11, maxLng: 2 } as const;

export function defaultRouteLimits(graceMs: number): RouteLimits {
  return {
    graceMs,
    maxPoints: MAX_ROUTE_POINTS,
    maxRouteM: MAX_ROUTE_M,
    maxDurationMs: MAX_SESSION_MS,
    maxSegmentMps: MAX_SEGMENT_MPS,
    maxMaskedFraction: MAX_MASKED_FRACTION,
    maxGapMs: MAX_GAP_MS,
    gapMinM: GAP_MIN_M,
    timeSlackMs: 60_000,
    futureSlackMs: 5 * 60_000,
  };
}

const M_PER_DEG_LAT = 111_319.5;

function mPerDegLng(lat: number): number {
  return M_PER_DEG_LAT * Math.cos((lat * Math.PI) / 180);
}

/** Equirectangular distance in metres — accurate to well under a metre at the
 *  segment scales used here, and cheap enough for per-segment speed checks. */
export function fastDistanceM(a: { lat: number; lng: number }, b: { lat: number; lng: number }): number {
  const dy = (b.lat - a.lat) * M_PER_DEG_LAT;
  const dx = (b.lng - a.lng) * mPerDegLng((a.lat + b.lat) / 2);
  return Math.hypot(dx, dy);
}

/**
 * Project [p] onto the segment [a]→[b] in a local tangent plane, clamping to
 * the segment (unlike _routePlanner.filterToCorridor, which skips projections
 * outside it — a box just past a vertex on the outside of a bend must still
 * match the vertex). Returns the clamped parameter t ∈ [0,1], the tangent-plane
 * distance and the projected point. A degenerate (zero-length) segment
 * projects everything onto [a].
 */
export function projectOntoSegment(
  p: { lat: number; lng: number },
  a: { lat: number; lng: number },
  b: { lat: number; lng: number },
): { t: number; distM: number; point: { lat: number; lng: number } } {
  const mPerLng = mPerDegLng((a.lat + b.lat) / 2);
  const bx = (b.lng - a.lng) * mPerLng;
  const by = (b.lat - a.lat) * M_PER_DEG_LAT;
  const px = (p.lng - a.lng) * mPerLng;
  const py = (p.lat - a.lat) * M_PER_DEG_LAT;
  const len2 = bx * bx + by * by;
  const raw = len2 > 0 ? (px * bx + py * by) / len2 : 0;
  const t = Math.max(0, Math.min(1, raw));
  const dx = px - t * bx;
  const dy = py - t * by;
  return {
    t,
    distM: Math.hypot(dx, dy),
    point: { lat: a.lat + t * (b.lat - a.lat), lng: a.lng + t * (b.lng - a.lng) },
  };
}

export type RouteRejectReason =
  | "too_few_points"
  | "too_many_points"
  | "bad_point"
  | "non_monotonic"
  | "outside_session"
  | "future"
  | "expired"
  | "too_long_duration"
  | "route_too_long"
  | "outside_region"
  | "implausible_speed";

export type RouteValidation =
  | {
      ok: true;
      /** usable[i] — whether segment i (points[i]→points[i+1]) may be matched. */
      usable: boolean[];
      lengthM: number;
      speedMaskedM: number;
    }
  | { ok: false; reason: RouteRejectReason };

/**
 * Validate a recorded route against its session bounds and the limits, and
 * mark which segments are trustworthy enough to match against. Order of
 * precedence: shape → time ordering → session bounds → freshness → size →
 * region → plausibility.
 */
export function validateRoute(
  points: RoutePoint[],
  session: { startMs: number; endMs: number },
  nowMs: number,
  limits: RouteLimits,
): RouteValidation {
  if (points.length < 2) return { ok: false, reason: "too_few_points" };
  if (points.length > limits.maxPoints) return { ok: false, reason: "too_many_points" };
  for (const p of points) {
    if (!Number.isFinite(p.lat) || !Number.isFinite(p.lng) || !Number.isFinite(p.tMs) ||
        p.lat < -90 || p.lat > 90 || p.lng < -180 || p.lng > 180) {
      return { ok: false, reason: "bad_point" };
    }
  }
  for (let i = 1; i < points.length; i++) {
    if (points[i].tMs < points[i - 1].tMs) return { ok: false, reason: "non_monotonic" };
  }
  if (!Number.isFinite(session.startMs) || !Number.isFinite(session.endMs) ||
      session.endMs < session.startMs) {
    return { ok: false, reason: "outside_session" };
  }
  const first = points[0].tMs;
  const last = points[points.length - 1].tMs;
  if (first < session.startMs - limits.timeSlackMs || last > session.endMs + limits.timeSlackMs) {
    return { ok: false, reason: "outside_session" };
  }
  if (session.endMs > nowMs + limits.futureSlackMs || last > nowMs + limits.futureSlackMs) {
    return { ok: false, reason: "future" };
  }
  // A route whose LAST point is past the window can't have a claimable pass.
  if (nowMs - last > limits.graceMs) return { ok: false, reason: "expired" };
  if (session.endMs - session.startMs > limits.maxDurationMs) {
    return { ok: false, reason: "too_long_duration" };
  }
  for (const p of points) {
    if (p.lat < BRITISH_ISLES.minLat || p.lat > BRITISH_ISLES.maxLat ||
        p.lng < BRITISH_ISLES.minLng || p.lng > BRITISH_ISLES.maxLng) {
      return { ok: false, reason: "outside_region" };
    }
  }

  const usable: boolean[] = [];
  let lengthM = 0;
  let speedMaskedM = 0;
  for (let i = 0; i < points.length - 1; i++) {
    const a = points[i];
    const b = points[i + 1];
    const d = fastDistanceM(a, b);
    const dtMs = b.tMs - a.tMs;
    lengthM += d;
    // Zero-time duplicates are harmless when they barely move; a jump with no
    // elapsed time is a teleport.
    const mps = dtMs > 0 ? d / (dtMs / 1000) : (d <= 5 ? 0 : Infinity);
    if (mps > limits.maxSegmentMps) {
      usable.push(false);
      speedMaskedM += d;
    } else if (dtMs > limits.maxGapMs && d > limits.gapMinM) {
      usable.push(false); // GPS dropout chord
    } else {
      usable.push(true);
    }
  }
  if (lengthM > limits.maxRouteM) return { ok: false, reason: "route_too_long" };
  if (lengthM > 0 && speedMaskedM / lengthM > limits.maxMaskedFraction) {
    return { ok: false, reason: "implausible_speed" };
  }
  return { ok: true, usable, lengthM, speedMaskedM };
}

/**
 * The geohash cells (at [precision]) covering every usable segment buffered by
 * [bufferM], plus an index from cell to the segments whose buffer touches it.
 * Long segments are split into CELL_PIECE_M pieces so each piece's buffered
 * bounding box stays tight. Returns null when the route would need more than
 * [maxCells] cells (route_too_large).
 *
 * Coverage guarantee: any point within bufferM of a usable segment lies in
 * that segment's buffered piece bbox, so its cell is in the set and maps to
 * the segment — matchRoute relies on this to test each box only against
 * nearby segments.
 */
export function coveringCells(
  points: RoutePoint[],
  usable: boolean[],
  bufferM: number,
  precision: number = ROUTE_CELL_PRECISION,
  maxCells: number = MAX_ROUTE_CELLS,
): Map<string, number[]> | null {
  const index = new Map<string, Set<number>>();
  for (let i = 0; i < usable.length; i++) {
    if (!usable[i]) continue;
    const a = points[i];
    const b = points[i + 1];
    const pieces = Math.max(1, Math.ceil(fastDistanceM(a, b) / CELL_PIECE_M));
    for (let k = 0; k < pieces; k++) {
      const t0 = k / pieces;
      const t1 = (k + 1) / pieces;
      const lat0 = a.lat + t0 * (b.lat - a.lat);
      const lng0 = a.lng + t0 * (b.lng - a.lng);
      const lat1 = a.lat + t1 * (b.lat - a.lat);
      const lng1 = a.lng + t1 * (b.lng - a.lng);
      const minLat = Math.min(lat0, lat1);
      const maxLat = Math.max(lat0, lat1);
      // Use the latitude furthest from the equator: the smallest metres per
      // degree of longitude gives the widest (conservative) longitude buffer.
      const dLat = bufferM / M_PER_DEG_LAT;
      const dLng = bufferM / mPerDegLng(Math.max(Math.abs(minLat), Math.abs(maxLat)) + dLat);
      const cells = geohash.bboxes(
        minLat - dLat,
        Math.min(lng0, lng1) - dLng,
        maxLat + dLat,
        Math.max(lng0, lng1) + dLng,
        precision,
      );
      for (const c of cells) {
        let segs = index.get(c);
        if (!segs) {
          if (index.size >= maxCells) return null;
          segs = new Set<number>();
          index.set(c, segs);
        }
        segs.add(i);
      }
    }
  }
  const out = new Map<string, number[]>();
  for (const [c, segs] of index) out.set(c, [...segs].sort((x, y) => x - y));
  return out;
}

/**
 * For each box, the closest pass by the route per London day, accepted only
 * when geolib.getDistance(anchor, box) <= radiusM (lookupPostboxes' exact
 * test). Boxes are tested only against the segments indexed under their own
 * cell. Results are sorted by pass time.
 */
export function matchRoute(
  points: RoutePoint[],
  usable: boolean[],
  boxes: RouteBox[],
  radiusM: number,
  cellIndex: Map<string, number[]>,
  precision: number = ROUTE_CELL_PRECISION,
): RoutePass[] {
  const passes: RoutePass[] = [];
  for (const box of boxes) {
    const segs = cellIndex.get(geohash.encode(box.lat, box.lng, precision));
    if (!segs) continue;
    const bestByDay = new Map<string, RoutePass>();
    for (const i of segs) {
      if (!usable[i]) continue;
      const a = points[i];
      const b = points[i + 1];
      const proj = projectOntoSegment(box, a, b);
      // Cheap reject before the exact check (tangent plane vs geolib differ
      // by far less than this margin at city scale).
      if (proj.distM > radiusM + 5) continue;
      const distanceM = geolib.getDistance(
        { latitude: proj.point.lat, longitude: proj.point.lng },
        { latitude: box.lat, longitude: box.lng },
      );
      if (distanceM > radiusM) continue;
      const passedAtMs = Math.round(a.tMs + proj.t * (b.tMs - a.tMs));
      const claimDate = getLondonDayOf(new Date(passedAtMs));
      const prev = bestByDay.get(claimDate);
      if (!prev || distanceM < prev.distanceM ||
          (distanceM === prev.distanceM && passedAtMs < prev.passedAtMs)) {
        bestByDay.set(claimDate, {
          boxId: box.id,
          monarch: box.monarch,
          boxLat: box.lat,
          boxLng: box.lng,
          point: proj.point,
          passedAtMs,
          claimDate,
          distanceM,
        });
      }
    }
    passes.push(...bestByDay.values());
  }
  return passes.sort((x, y) => x.passedAtMs - y.passedAtMs || x.boxId.localeCompare(y.boxId));
}

/**
 * Greedily group time-sorted passes into one-quiz candidates: a group starts
 * at its first pass's anchor and absorbs later same-day passes within
 * [maxDtMs] whose BOX is within [radiusM] of that anchor (geolib, so the
 * claim at the anchor finds every box in the group).
 */
export function groupPasses(
  passes: RoutePass[],
  radiusM: number,
  maxDtMs: number = GROUP_MAX_DT_MS,
): CandidateGroup[] {
  const sorted = [...passes].sort((x, y) => x.passedAtMs - y.passedAtMs || x.boxId.localeCompare(y.boxId));
  const used = new Set<number>();
  const groups: CandidateGroup[] = [];
  for (let i = 0; i < sorted.length; i++) {
    if (used.has(i)) continue;
    const head = sorted[i];
    used.add(i);
    const group: CandidateGroup = {
      boxIds: [head.boxId],
      monarchs: [head.monarch],
      anchor: head.point,
      passedAtMs: head.passedAtMs,
      claimDate: head.claimDate,
    };
    for (let j = i + 1; j < sorted.length; j++) {
      if (used.has(j)) continue;
      const p = sorted[j];
      if (p.passedAtMs - head.passedAtMs > maxDtMs) break;
      if (p.claimDate !== head.claimDate) continue;
      if (group.boxIds.includes(p.boxId)) continue;
      const d = geolib.getDistance(
        { latitude: head.point.lat, longitude: head.point.lng },
        { latitude: p.boxLat, longitude: p.boxLng },
      );
      if (d > radiusM) continue;
      used.add(j);
      group.boxIds.push(p.boxId);
      group.monarchs.push(p.monarch);
    }
    groups.push(group);
  }
  return groups;
}

/** Stable digest of a route's points — lets the server recognise an unchanged
 *  re-submission (app reopen, network retry) and re-match it free of quota. */
export function routeDigest(points: RoutePoint[]): string {
  const h = createHash("sha256");
  for (const p of points) h.update(`${p.tMs},${p.lat.toFixed(6)},${p.lng.toFixed(6)};`);
  return h.digest("hex").slice(0, 16);
}
