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
