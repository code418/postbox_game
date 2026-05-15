/**
 * _routePlanner.ts — pure route-planning helpers shared between the
 * plan_route CLI script and the routePostboxes Cloud Function.
 *
 * No firebase-admin, no fs, no process imports — safe to require in any context.
 */

import * as geolib from "geolib";

// ---------- types ----------

export type Point = { lat: number; lng: number };

export type Candidate = {
  id: string;
  lat: number;
  lng: number;
  monarch: string | null;
  points: number;
  reference?: string;
  county?: string;
};

export type RouteStop = {
  postbox: Candidate;
  legMeters: number;
  cumSeconds: number;
};

export type SearchState = {
  current: Point;
  currentId: string;
  visited: Set<string>;
  visitedKey: string;
  timeUsed: number;
  score: number;
  route: RouteStop[];
};

// ---------- geometry helpers ----------

/** Wrapper over geolib.getDistance for lat/lng Points. */
export function metresBetween(a: Point, b: Point): number {
  return geolib.getDistance({ latitude: a.lat, longitude: a.lng }, { latitude: b.lat, longitude: b.lng });
}

/** Crude lat/lng average midpoint — fine at city scale. */
export function midpoint(a: Point, b: Point): Point {
  return { lat: (a.lat + b.lat) / 2, lng: (a.lng + b.lng) / 2 };
}

/**
 * Retain candidates reachable within budgetMetres via start→candidate→end
 * (i.e. they lie inside the time ellipse formed by the two foci).
 */
export function filterToEllipse(
  candidates: Candidate[],
  start: Point,
  end: Point,
  budgetMetres: number,
): Candidate[] {
  const out: Candidate[] = [];
  for (const c of candidates) {
    const p: Point = { lat: c.lat, lng: c.lng };
    if (metresBetween(start, p) + metresBetween(p, end) <= budgetMetres) out.push(c);
  }
  return out;
}

/**
 * Retain candidates that are within halfWidthMetres of the start-end segment
 * AND whose projection onto that segment falls between the two endpoints
 * (0 ≤ t ≤ 1 in normalised segment coordinates).
 *
 * Uses a local-tangent-plane approximation (small-angle) around the midpoint,
 * valid at city scale where 1° lat ≈ 111 km and 1° lng ≈ 111·cos(lat) km.
 */
export function filterToCorridor(
  candidates: Candidate[],
  start: Point,
  end: Point,
  halfWidthMetres: number,
): Candidate[] {
  const mid = midpoint(start, end);
  // Metres-per-degree scale factors at the midpoint latitude.
  const mPerLat = 111_319.5;
  const mPerLng = 111_319.5 * Math.cos((mid.lat * Math.PI) / 180);

  // Segment vector in metres (local tangent plane).
  const sx = (end.lng - start.lng) * mPerLng;
  const sy = (end.lat - start.lat) * mPerLat;
  const segLenSq = sx * sx + sy * sy;

  const out: Candidate[] = [];
  for (const c of candidates) {
    const px = (c.lng - start.lng) * mPerLng;
    const py = (c.lat - start.lat) * mPerLat;

    // Projection parameter along segment (0 = start, 1 = end).
    const t = segLenSq > 0 ? (px * sx + py * sy) / segLenSq : 0;
    if (t < 0 || t > 1) continue;

    // Perpendicular distance.
    const perpX = px - t * sx;
    const perpY = py - t * sy;
    const perpDist = Math.sqrt(perpX * perpX + perpY * perpY);
    if (perpDist <= halfWidthMetres) out.push(c);
  }
  return out;
}

/**
 * Beam-search orienteering solver.
 *
 * Explores combinations of postboxes that maximise score while keeping the
 * total walk time (travel + per-claim dwell) within budgetSeconds, leaving
 * enough time to reach `end` from the last visited postbox.
 */
export function beamSearchOrienteering(
  start: Point,
  end: Point,
  candidates: Candidate[],
  budgetSeconds: number,
  speedMps: number,
  perClaimSeconds: number,
  beamWidth: number,
): SearchState {
  const initial: SearchState = {
    current: start,
    currentId: "__START__",
    visited: new Set(),
    visitedKey: "",
    timeUsed: 0,
    score: 0,
    route: [],
  };

  let best = initial;
  let beam: SearchState[] = [initial];

  while (beam.length > 0) {
    const next: SearchState[] = [];
    const dedup = new Map<string, SearchState>();

    for (const state of beam) {
      for (const c of candidates) {
        if (state.visited.has(c.id)) continue;
        const legMetres = metresBetween(state.current, { lat: c.lat, lng: c.lng });
        const closingMetres = metresBetween({ lat: c.lat, lng: c.lng }, end);
        const newTime = state.timeUsed + legMetres / speedMps + perClaimSeconds;
        if (newTime + closingMetres / speedMps > budgetSeconds) continue;

        const visited = new Set(state.visited);
        visited.add(c.id);
        const visitedKey = Array.from(visited).sort().join("|");
        const dedupKey = `${c.id}|${visitedKey}`;
        const existing = dedup.get(dedupKey);
        if (existing && existing.timeUsed <= newTime) continue;

        const candidateState: SearchState = {
          current: { lat: c.lat, lng: c.lng },
          currentId: c.id,
          visited,
          visitedKey,
          timeUsed: newTime,
          score: state.score + c.points,
          route: [...state.route, { postbox: c, legMeters: legMetres, cumSeconds: newTime }],
        };
        dedup.set(dedupKey, candidateState);
      }
    }

    for (const s of dedup.values()) {
      next.push(s);
      if (s.score > best.score || (s.score === best.score && s.timeUsed < best.timeUsed)) best = s;
    }

    next.sort((a, b) => (b.score - a.score) || (a.timeUsed - b.timeUsed));
    beam = next.slice(0, beamWidth);
  }

  return best;
}

/**
 * Compute the final leg from the last visited stop to the destination and
 * return the complete route summary.
 */
export function finaliseRoute(
  state: SearchState,
  end: Point,
  speedMps: number,
): {
  state: SearchState;
  closingMetres: number;
  closingSeconds: number;
  totalMetres: number;
  totalSeconds: number;
} {
  const closingMetres = metresBetween(state.current, end);
  const closingSeconds = closingMetres / speedMps;
  const totalSeconds = state.timeUsed + closingSeconds;
  const totalMetres = state.route.reduce((s, r) => s + r.legMeters, 0) + closingMetres;
  return { state, closingMetres, closingSeconds, totalMetres, totalSeconds };
}
