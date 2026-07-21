// Server-side game-balance config, backed by Firebase Remote Config.
//
// v1.4 ship gate: `claim_radius_meters` and `points_by_monarch` are driven
// end-to-end (client + Cloud Functions) with safety bounds enforced. This
// module is the SERVER half — it reads the Remote Config *server* template,
// caches the evaluated values in-memory for 5 minutes (so hot callables pay
// nothing), and NEVER throws: on any fetch/parse failure it returns the
// hard-coded fallbacks so scoring degrades to today's behaviour.
//
// The hard-coded fallbacks (DEFAULT_CLAIM_RADIUS_METERS here, getPoints in
// _getPoints.ts) remain the canonical values guarded by
// test/cross_language_sync_test.dart. Remote Config is only an override on top.

import "./adminInit";
import * as admin from "firebase-admin";
import { KNOWN_MONARCHS, pointsForMonarch } from "./_getPoints";

/** Remote Config parameter keys (must match the client + the RC templates). */
export const KEY_CLAIM_RADIUS = "claim_radius_meters";
export const KEY_POINTS_BY_MONARCH = "points_by_monarch";

/** Canonical claim radius (metres). Must match AppPreferences.claimRadiusMeters
 *  in lib/app_preferences.dart and CLAIM_RADIUS_METERS in startScoring.ts. */
export const DEFAULT_CLAIM_RADIUS_METERS = 30;

/** Safety band for a Remote-Config-supplied claim radius. A value outside this
 *  band is treated as a misconfiguration and ignored (fall back to default). */
export const MIN_CLAIM_RADIUS_METERS = 10;
export const MAX_CLAIM_RADIUS_METERS = 100;

/** Safety band for a Remote-Config-supplied per-monarch point value. */
export const MIN_MONARCH_POINTS = 1;
export const MAX_MONARCH_POINTS = 50;

/** How long an evaluated config is reused before the next fetch. */
export const CONFIG_CACHE_TTL_MS = 5 * 60 * 1000;

export interface GameConfig {
  claimRadiusMeters: number;
  /** Recognised-monarch -> points overrides, or null to use the hard-coded
   *  points wholesale (invalid / absent Remote Config). */
  pointsOverride: Record<string, number> | null;
}

const FALLBACK_CONFIG: GameConfig = {
  claimRadiusMeters: DEFAULT_CLAIM_RADIUS_METERS,
  pointsOverride: null,
};

/** Clamp a Remote-Config claim radius into the safety band, or fall back to the
 *  default when it is missing / non-finite / out of band. */
export function sanitiseClaimRadius(raw: unknown): number {
  if (typeof raw !== "number" || !Number.isFinite(raw)) {
    return DEFAULT_CLAIM_RADIUS_METERS;
  }
  if (raw < MIN_CLAIM_RADIUS_METERS || raw > MAX_CLAIM_RADIUS_METERS) {
    return DEFAULT_CLAIM_RADIUS_METERS;
  }
  return raw;
}

/** Parse+validate the `points_by_monarch` JSON string. Returns a map of
 *  recognised monarch -> points (integers in [1,50]); unknown keys are dropped.
 *  Returns null (=> use the hard-coded points wholesale) if the string is
 *  absent, not a JSON object, or ANY value is a non-integer / out of range. */
export function parsePointsOverride(raw: unknown): Record<string, number> | null {
  if (typeof raw !== "string" || raw.trim().length === 0) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return null;
  }
  const known = new Set<string>(KNOWN_MONARCHS);
  const out: Record<string, number> = {};
  for (const [key, value] of Object.entries(parsed as Record<string, unknown>)) {
    if (!known.has(key)) continue; // drop unknown keys
    if (typeof value !== "number" || !Number.isInteger(value)) return null;
    if (value < MIN_MONARCH_POINTS || value > MAX_MONARCH_POINTS) return null;
    out[key] = value;
  }
  return out;
}

/** Pure resolution: the override value for [monarch] if present, else the
 *  hard-coded fallback (pointsForMonarch). */
export function resolvePointsForMonarch(
  cfg: GameConfig,
  monarch: string | null | undefined,
): number {
  if (
    cfg.pointsOverride &&
    typeof monarch === "string" &&
    Object.prototype.hasOwnProperty.call(cfg.pointsOverride, monarch)
  ) {
    return cfg.pointsOverride[monarch];
  }
  return pointsForMonarch(monarch);
}

/** Build a GameConfig from raw Remote Config values via the pure sanitisers. */
export function buildGameConfig(rawRadius: unknown, rawPoints: unknown): GameConfig {
  return {
    claimRadiusMeters: sanitiseClaimRadius(rawRadius),
    pointsOverride: parsePointsOverride(rawPoints),
  };
}

type ConfigLoader = () => Promise<GameConfig>;

/** Real loader: read + evaluate the Remote Config server template. Never throws
 *  — any failure yields the fallback config. */
async function fetchGameConfigFromRemoteConfig(): Promise<GameConfig> {
  try {
    const template = await admin.remoteConfig().getServerTemplate();
    const config = template.evaluate();
    const rawRadius = config.getValue(KEY_CLAIM_RADIUS).asNumber();
    const rawPoints = config.getValue(KEY_POINTS_BY_MONARCH).asString();
    return buildGameConfig(rawRadius, rawPoints);
  } catch (e) {
    console.warn("[_config] Remote Config fetch failed; using fallbacks:", e);
    return FALLBACK_CONFIG;
  }
}

let loader: ConfigLoader = fetchGameConfigFromRemoteConfig;
let cache: { value: GameConfig; fetchedAtMs: number } | null = null;

/** The evaluated game config, cached for CONFIG_CACHE_TTL_MS. `nowMs` is
 *  injectable for tests; production passes the default Date.now(). */
export async function getGameConfig(nowMs: number = Date.now()): Promise<GameConfig> {
  if (cache && nowMs - cache.fetchedAtMs < CONFIG_CACHE_TTL_MS) {
    return cache.value;
  }
  const value = await loader();
  cache = { value, fetchedAtMs: nowMs };
  return value;
}

export async function getClaimRadiusMeters(): Promise<number> {
  return (await getGameConfig()).claimRadiusMeters;
}

export async function getPointsForMonarch(monarch: string | null | undefined): Promise<number> {
  return resolvePointsForMonarch(await getGameConfig(), monarch);
}

/** Test hook: swap the config loader (dependency injection for cache tests). */
export function setConfigLoaderForTest(l: ConfigLoader): void {
  loader = l;
  cache = null;
}

/** Test hook: clear the in-memory cache (leaves the loader as-is). */
export function resetConfigCacheForTest(): void {
  cache = null;
}
