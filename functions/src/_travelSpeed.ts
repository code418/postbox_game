import * as geolib from "geolib";

/** Maximum plausible travel speed between two successive claims.
 *  1900 metres per minute (~31.67 m/s, ~114 km/h) is a deliberately liberal
 *  upper bound — anything faster is almost certainly a spoofed GPS fix. */
export const MAX_METRES_PER_MIN = 1900;

export interface TravelSpeedCheckInput {
  lastLat: number;
  lastLng: number;
  lastTimestampMs: number;
  currentLat: number;
  currentLng: number;
  nowMs: number;
}

export interface TravelSpeedCheckResult {
  ok: boolean;
  /** Implied speed in metres/minute, for logging/diagnostics. */
  speedMPerMin: number;
  distanceMetres: number;
  elapsedMinutes: number;
}

/** Decide whether the user's implied travel speed from their previous claim is
 *  plausible.  A sub-second delta is floored to 1 second to avoid division
 *  blow-ups; a large jump over that second still triggers rejection because
 *  distance/(1/60) = 60 × distance, which will exceed the limit well before
 *  physiological plausibility.  Returns ok=true when no time has elapsed and
 *  the user hasn't moved — this matches the no-movement case after a clock
 *  skew. */
export function checkTravelSpeed(input: TravelSpeedCheckInput): TravelSpeedCheckResult {
  const distanceMetres = geolib.getDistance(
    { latitude: input.lastLat, longitude: input.lastLng },
    { latitude: input.currentLat, longitude: input.currentLng }
  );
  const rawElapsedMs = Math.max(0, input.nowMs - input.lastTimestampMs);
  const flooredElapsedMs = Math.max(rawElapsedMs, 1000);
  const elapsedMinutes = flooredElapsedMs / 60000;
  const speedMPerMin = distanceMetres / elapsedMinutes;
  return {
    ok: speedMPerMin <= MAX_METRES_PER_MIN,
    speedMPerMin,
    distanceMetres,
    elapsedMinutes,
  };
}

/** A claim adjacent (by eventTime) to the one being adjudicated. */
export interface NeighbourPoint {
  lat: number;
  lng: number;
  tMs: number;
}

export interface NeighbourSpeedResult {
  ok: boolean;
  /** Implied speed vs the previous neighbour (persisted as `travelSpeed`). */
  speedPrev?: number;
  /** Implied speed vs the next neighbour (diagnostics only). */
  speedNext?: number;
}

/**
 * Two-sided travel-speed check (ROADMAP v1.5, offline play Phase 2): a claim
 * at time `t` must be physically plausible against BOTH the nearest stored
 * claim before `t` and the nearest after it.
 *
 * One-sided checks ("reject anything older than your newest claim") would
 * permanently strand a legitimate late flush; two-sided INSERTS into the
 * timeline instead — and catches backdating a capture to just before a
 * known-distant live claim, which the prev-only check cannot see.
 *
 * Pure composition over [checkTravelSpeed] (whose signature is pinned by a
 * substantial test suite and must not change).
 */
export function checkNeighbourSpeeds(
  current: NeighbourPoint,
  prev?: NeighbourPoint,
  next?: NeighbourPoint,
): NeighbourSpeedResult {
  let speedPrev: number | undefined;
  let speedNext: number | undefined;
  let ok = true;
  if (prev) {
    const r = checkTravelSpeed({
      lastLat: prev.lat,
      lastLng: prev.lng,
      lastTimestampMs: prev.tMs,
      currentLat: current.lat,
      currentLng: current.lng,
      nowMs: current.tMs,
    });
    speedPrev = r.speedMPerMin;
    ok = ok && r.ok;
  }
  if (next) {
    const r = checkTravelSpeed({
      lastLat: current.lat,
      lastLng: current.lng,
      lastTimestampMs: current.tMs,
      currentLat: next.lat,
      currentLng: next.lng,
      nowMs: next.tMs,
    });
    speedNext = r.speedMPerMin;
    ok = ok && r.ok;
  }
  return { ok, speedPrev, speedNext };
}
