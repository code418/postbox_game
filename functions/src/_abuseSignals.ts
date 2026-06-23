// Pure abuse-detection helpers for the shadow-mode claim anomaly detector.
//
// These functions intentionally hold no Firestore/IO so they're unit-testable
// without an emulator (same approach as buildOsmChange / nextQuotaState in
// reports.ts). The onClaimCreated trigger (abuse.ts) wires them to claim data.
//
// SHADOW MODE: signals are recorded, never used to block or void a claim.
//
// Thresholds are constants for now; a follow-up makes them Remote-Config-driven
// alongside the v1.4 "Remote Config for game balance" item.

import { MAX_METRES_PER_MIN } from "./_travelSpeed";

/** Implied-travel speed (m/min) at or above which a claim is *flagged* in shadow
 *  mode. Deliberately BELOW the live hard reject (MAX_METRES_PER_MIN = 1900 in
 *  _travelSpeed.ts): claims above the hard limit never get created, so a flag
 *  threshold ≥ 1900 would be dead code. 1500 m/min (~90 km/h) surfaces the
 *  fast-but-not-rejected band for offline tuning. */
export const SHADOW_TRAVEL_FLAG_M_PER_MIN = 1500;

/** Max tolerated gap between the server's claim timestamp and the client-supplied
 *  timestamp before the claim is flagged as out-of-window (clock skew / replay). */
export const OUT_OF_WINDOW_MS = 120_000; // 2 minutes

/** Decimal places to which a claim's coordinate is rounded for clustering. */
export const CLUSTER_DECIMALS = 6;

/** Number of prior claims at the identical rounded coordinate that trips the
 *  clustering signal (the current claim plus this many repeats). */
export const CLUSTER_MIN_REPEATS = 3;

/** Trust score assigned to a user with no prior flags. */
export const DEFAULT_TRUST_SCORE = 100;

// Sanity: the shadow flag must stay below the hard reject or it can never fire.
if (SHADOW_TRAVEL_FLAG_M_PER_MIN >= MAX_METRES_PER_MIN) {
  throw new Error("SHADOW_TRAVEL_FLAG_M_PER_MIN must be below MAX_METRES_PER_MIN");
}

export type Severity = "low" | "med" | "high";

export interface SignalResult {
  /** True when this signal's threshold was breached. */
  flagged: boolean;
  /** The measured quantity (speed / delta-ms / repeat-count) for diagnostics. */
  value: number;
}

export interface NamedSignal {
  reason: string;
  flagged: boolean;
}

/** Stable string key grouping claims that share a coordinate to `decimals` dp.
 *  Used both by startScoring (stored on the claim) and the trigger (equality
 *  query), so it must be deterministic. */
export function coordKey(lat: number, lng: number, decimals = CLUSTER_DECIMALS): string {
  return `${lat.toFixed(decimals)},${lng.toFixed(decimals)}`;
}

/** Impossible-travel signal. `travelSpeedMPerMin` is the value startScoring
 *  already computed against the user's previous claim; undefined means there was
 *  no previous claim to compare against (first claim), so nothing is flagged. */
export function impossibleTravelSignal(travelSpeedMPerMin?: number): SignalResult {
  if (travelSpeedMPerMin === undefined || !Number.isFinite(travelSpeedMPerMin)) {
    return { flagged: false, value: 0 };
  }
  return {
    flagged: travelSpeedMPerMin >= SHADOW_TRAVEL_FLAG_M_PER_MIN,
    value: travelSpeedMPerMin,
  };
}

/** Out-of-window signal: the client's reported timestamp disagrees with the
 *  server's by more than OUT_OF_WINDOW_MS. Absent client timestamp (legacy/web
 *  clients) is not flagged. */
export function outOfWindowSignal(serverTsMs: number, clientTsMs?: number): SignalResult {
  if (clientTsMs === undefined || !Number.isFinite(clientTsMs)) {
    return { flagged: false, value: 0 };
  }
  const delta = Math.abs(serverTsMs - clientTsMs);
  return { flagged: delta > OUT_OF_WINDOW_MS, value: delta };
}

/** Coordinate-clustering signal: the user has claimed from the identical rounded
 *  coordinate at least CLUSTER_MIN_REPEATS times. `repeatCount` is supplied by
 *  the caller from a Firestore count query on `coordKey6`. */
export function coordClusterSignal(repeatCount: number): SignalResult {
  return { flagged: repeatCount >= CLUSTER_MIN_REPEATS, value: repeatCount };
}

function severityForCount(n: number): Severity {
  if (n >= 3) return "high";
  if (n === 2) return "med";
  return "low";
}

/** Reduce the fired signals to the reason list + an overall severity that rises
 *  as signals co-occur (a single signal is "low"; the future enforcement phase
 *  requires ≥ 2 before acting). */
export function summariseFlags(signals: NamedSignal[]): { reasons: string[]; severity: Severity } {
  const reasons = signals.filter((s) => s.flagged).map((s) => s.reason);
  return { reasons, severity: severityForCount(reasons.length) };
}

const DECAY_BY_SEVERITY: Record<Severity, number> = { low: 5, med: 15, high: 30 };

/** Apply a trust-score penalty for a flag of the given severity, clamped to
 *  [0, DEFAULT_TRUST_SCORE]. Time-based recovery is a deferred follow-up. */
export function applyTrustDecay(current: number, severity: Severity): number {
  const next = current - DECAY_BY_SEVERITY[severity];
  return Math.max(0, Math.min(DEFAULT_TRUST_SCORE, next));
}
