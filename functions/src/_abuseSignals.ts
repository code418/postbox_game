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

import * as geolib from "geolib";
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

/** Number of distinct accounts sharing one device hash within 24h that trips the
 *  repeated-device signal (multi-accounting from a single install). */
export const REPEATED_DEVICE_MIN_ACCOUNTS = 3;

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

/** Repeated-device signal: the number of DISTINCT accounts that have claimed
 *  from the same device hash within the recent window reaches
 *  REPEATED_DEVICE_MIN_ACCOUNTS. `distinctAccounts` is supplied by the caller
 *  from a Firestore query over recent claims sharing the deviceIdHash. */
export function repeatedDeviceSignal(distinctAccounts: number): SignalResult {
  return { flagged: distinctAccounts >= REPEATED_DEVICE_MIN_ACCOUNTS, value: distinctAccounts };
}

// ── Offline-flush signals (v1.5, shadow mode) ───────────────────────────────

/** Fraction of the grace window past which a flushed capture's queue time is
 *  flagged. A capture flushed at 90%+ of the window is exactly the shape of a
 *  saved-and-replayed outbox probing the ceiling. */
export const QUEUED_CEILING_FRACTION = 0.9;

/** Minimum flush batch size for the constant-speed signal — a pair of legs
 *  can be coincidentally regular; three or more raise the bar. */
export const CONSTANT_SPEED_MIN_BATCH = 3;

/** Coefficient-of-variation ceiling below which a batch's implied speeds are
 *  suspiciously metronome-regular (a human doing a postbox round stops,
 *  waits, gets a coffee). */
export const CONSTANT_SPEED_MAX_CV = 0.15;

/** Mean implied speed (m/min) below which the constant-speed signal declines
 *  to judge — a stationary batch is regular but not suspicious. */
export const CONSTANT_SPEED_MIN_MEAN_M_PER_MIN = 20;

/** Queued-too-long signal: the capture sat in the outbox for at least
 *  QUEUED_CEILING_FRACTION of the grace window before flushing. */
export function queuedTooLongSignal(queuedForMs: number | undefined, graceMs: number): SignalResult {
  if (queuedForMs === undefined || !Number.isFinite(queuedForMs) ||
      !Number.isFinite(graceMs) || graceMs <= 0) {
    return { flagged: false, value: 0 };
  }
  return { flagged: queuedForMs >= graceMs * QUEUED_CEILING_FRACTION, value: queuedForMs };
}

/** Coefficient of variation (stddev / mean) of the implied speeds across a
 *  batch's consecutive capture legs. Returns undefined when there are fewer
 *  than CONSTANT_SPEED_MIN_BATCH points, any leg has a non-positive time
 *  delta, or the mean speed is below the stationary floor — those batches
 *  carry no judgeable signal. Computed at FLUSH time (the only place the
 *  whole batch is visible) and stored per-claim as `batchSpeedCv`. */
export function computeBatchSpeedCv(
  points: Array<{ lat: number; lng: number; tMs: number }>,
): number | undefined {
  if (points.length < CONSTANT_SPEED_MIN_BATCH) return undefined;
  const speeds: number[] = [];
  for (let i = 1; i < points.length; i++) {
    const dtMin = (points[i].tMs - points[i - 1].tMs) / 60_000;
    if (dtMin <= 0) return undefined;
    const dist = geolib.getDistance(
      { latitude: points[i - 1].lat, longitude: points[i - 1].lng },
      { latitude: points[i].lat, longitude: points[i].lng },
    );
    speeds.push(dist / dtMin);
  }
  const mean = speeds.reduce((a, b) => a + b, 0) / speeds.length;
  if (mean < CONSTANT_SPEED_MIN_MEAN_M_PER_MIN) return undefined;
  const variance = speeds.reduce((a, b) => a + (b - mean) ** 2, 0) / speeds.length;
  return Math.sqrt(variance) / mean;
}

/** Constant-batch-speed signal: a flush batch of ≥ CONSTANT_SPEED_MIN_BATCH
 *  captures whose implied speeds are near-uniform (a synthesised trace). */
export function constantBatchSpeedSignal(
  batchSpeedCv: number | undefined,
  batchSize: number | undefined,
): SignalResult {
  if (batchSpeedCv === undefined || !Number.isFinite(batchSpeedCv) ||
      batchSize === undefined || batchSize < CONSTANT_SPEED_MIN_BATCH) {
    return { flagged: false, value: 0 };
  }
  return { flagged: batchSpeedCv <= CONSTANT_SPEED_MAX_CV, value: batchSpeedCv };
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

/** Inputs the onClaimCreated trigger gathers from the claim + Firestore, fed to
 *  the pure signal evaluator so the combination logic is unit-testable. */
export interface ClaimSignalInputs {
  travelSpeedMPerMin?: number;
  serverTsMs: number;
  clientTsMs?: number;
  coordRepeatCount: number;
  distinctDeviceAccounts: number;
  /** True when the claim was written by the flush path — derived server-side
   *  from the claim's `offline` field, which only flushOfflineClaims writes. */
  offline?: boolean;
  /** Flush-time client wall-clock. For an offline claim the out-of-window
   *  signal compares THIS against serverTs — the capture-time clientTsMs is
   *  legitimately hours old, while a skewed flush clock is precisely the
   *  tampered-device-clock attack this path opens. */
  flushClientTsMs?: number;
  queuedForMs?: number;
  /** The grace window active when the claim was flushed (for the ceiling
   *  fraction). */
  graceMs?: number;
  batchSize?: number;
  batchSpeedCv?: number;
}

export interface ClaimSignalEvaluation {
  reasons: string[];
  severity: Severity;
  signals: {
    travelSpeedMPerMin: number;
    clockSkewMs: number;
    coordRepeatCount: number;
    deviceAccountCount: number;
    queuedForMs: number;
    batchSpeedCv: number;
  };
}

/** Evaluate every shadow-mode anomaly signal for one claim and reduce to the
 *  fired-reason list, an overall severity, and the measured values for the flag
 *  doc. Pure — the trigger supplies the IO-derived inputs. */
export function evaluateClaimSignals(inp: ClaimSignalInputs): ClaimSignalEvaluation {
  const travel = impossibleTravelSignal(inp.travelSpeedMPerMin);
  // Offline claims: judge clock skew at FLUSH time; the capture-time client
  // clock is expected to be far from the server write time.
  const window = outOfWindowSignal(
    inp.serverTsMs,
    inp.offline === true ? inp.flushClientTsMs : inp.clientTsMs,
  );
  const cluster = coordClusterSignal(inp.coordRepeatCount);
  const device = repeatedDeviceSignal(inp.distinctDeviceAccounts);
  const queued = inp.offline === true
    ? queuedTooLongSignal(inp.queuedForMs, inp.graceMs ?? 0)
    : { flagged: false, value: 0 };
  const constantSpeed = inp.offline === true
    ? constantBatchSpeedSignal(inp.batchSpeedCv, inp.batchSize)
    : { flagged: false, value: 0 };
  const { reasons, severity } = summariseFlags([
    { reason: "impossible_travel", flagged: travel.flagged },
    { reason: "out_of_window", flagged: window.flagged },
    { reason: "coord_cluster", flagged: cluster.flagged },
    { reason: "repeated_device", flagged: device.flagged },
    { reason: "queued_near_ceiling", flagged: queued.flagged },
    { reason: "constant_batch_speed", flagged: constantSpeed.flagged },
  ]);
  return {
    reasons,
    severity,
    signals: {
      travelSpeedMPerMin: travel.value,
      clockSkewMs: window.value,
      coordRepeatCount: cluster.value,
      deviceAccountCount: device.value,
      queuedForMs: queued.value,
      batchSpeedCv: constantSpeed.value,
    },
  };
}

const DECAY_BY_SEVERITY: Record<Severity, number> = { low: 5, med: 15, high: 30 };

/** Apply a trust-score penalty for a flag of the given severity, clamped to
 *  [0, DEFAULT_TRUST_SCORE]. Time-based recovery is a deferred follow-up. */
export function applyTrustDecay(current: number, severity: Severity): number {
  const next = current - DECAY_BY_SEVERITY[severity];
  return Math.max(0, Math.min(DEFAULT_TRUST_SCORE, next));
}
