// Workout-claim (Health Connect) configuration and rollout gates.
//
// WHY THIS READS THE CLIENT TEMPLATE: the Remote Config SERVER template is
// not published for this project (getServerTemplate() → remote-config/
// not-found), so anything read through getGameConfig() is always the
// hard-coded fallback — a kill switch read that way would never fire. The
// CLIENT template is the one actually managed and published, so its default
// values are read here directly via the Admin SDK (as the review dashboard
// does for maintenance_mode). Conditional values (e.g. the Admin audience)
// are NOT evaluated server-side: only the template's defaultValue counts.
//
// The server-side rollout gate is the ACTIVITY_CLAIMS_AUDIENCE env var
// (default "admin"), not Remote Config: it is set per function at deploy
// time, can't be bypassed by a client, and fails closed when unset.

import "./adminInit";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import { clientTemplateFlag, getGameConfig } from "./_config";

export const KEY_ACTIVITY_CLAIMS_ENABLED = "activity_claims_enabled";
export const KEY_KILL_SWITCH_ACTIVITY = "kill_switch_activity_claims";
export const KEY_ACTIVITY_GRACE_HOURS = "activity_claim_grace_hours";
export const KEY_ACTIVITY_ORIGIN_ALLOWLIST = "activity_origin_allowlist";

/** How long after a box is passed it stays claimable. Mirrored in
 *  lib/remote_config_service.dart (pinned by cross_language_sync_test). */
export const DEFAULT_ACTIVITY_GRACE_HOURS = 36;
export const MIN_ACTIVITY_GRACE_HOURS = 1;
export const MAX_ACTIVITY_GRACE_HOURS = 168;

/** Package names of fitness apps whose recorded routes are accepted. Health
 *  Connect lets ANY app with route-write access write routes, so this narrows
 *  the field to apps that record real GPS workouts. Mirrored (as the same JSON
 *  string) in lib/remote_config_service.dart and remoteconfig.template.json. */
export const DEFAULT_ACTIVITY_ORIGIN_ALLOWLIST: readonly string[] = [
  "com.fitbit.FitbitMobile",
  "com.google.android.apps.fitness",
  "com.sec.android.app.shealth",
  "com.garmin.android.apps.connectmobile",
  "com.strava",
];

/** Exercise types that may claim. Mirrored in the Kotlin bridge
 *  (HealthConnectMapping.kt) and lib/activity/activity_helpers.dart. */
export const ELIGIBLE_EXERCISE_TYPES = ["walking", "running", "hiking"] as const;
export type EligibleExerciseType = typeof ELIGIBLE_EXERCISE_TYPES[number];

/** Per-user daily budgets. Constants for now (the server template is
 *  unpublished); they bound Firestore reads and points farming. */
export const MAX_ACTIVITY_SESSIONS_PER_DAY = 12;
export const MAX_ACTIVITY_ROUTE_M_PER_DAY = 150_000;
export const MAX_ACTIVITY_CLAIMS_PER_DAY = 40;

export interface ActivityConfig {
  killed: boolean;
  maintenance: boolean;
  graceHours: number;
  originAllowlist: string[];
  maxSessionsPerDay: number;
  maxRouteMPerDay: number;
  maxClaimsPerDay: number;
}

export const FALLBACK_ACTIVITY_CONFIG: ActivityConfig = {
  killed: false,
  maintenance: false,
  graceHours: DEFAULT_ACTIVITY_GRACE_HOURS,
  originAllowlist: [...DEFAULT_ACTIVITY_ORIGIN_ALLOWLIST],
  maxSessionsPerDay: MAX_ACTIVITY_SESSIONS_PER_DAY,
  maxRouteMPerDay: MAX_ACTIVITY_ROUTE_M_PER_DAY,
  maxClaimsPerDay: MAX_ACTIVITY_CLAIMS_PER_DAY,
};

/** Clamp a grace window (hours) into its band; anything else → default. */
export function sanitiseActivityGraceHours(raw: unknown): number {
  const n = typeof raw === "string" && raw.trim() !== "" ? Number(raw) : raw;
  if (typeof n !== "number" || !Number.isInteger(n)) return DEFAULT_ACTIVITY_GRACE_HOURS;
  if (n < MIN_ACTIVITY_GRACE_HOURS || n > MAX_ACTIVITY_GRACE_HOURS) return DEFAULT_ACTIVITY_GRACE_HOURS;
  return n;
}

const PACKAGE_RE = /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$/;

/** Parse the allowlist JSON (an array of Android package names). Returns null
 *  for anything malformed or empty, so a bad publish falls back to the
 *  default rather than locking every source out (or letting any in). */
export function parseOriginAllowlist(raw: unknown): string[] | null {
  if (typeof raw !== "string" || raw.trim().length === 0) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!Array.isArray(parsed) || parsed.length === 0 || parsed.length > 50) return null;
  if (!parsed.every((p) => typeof p === "string" && p.length <= 128 && PACKAGE_RE.test(p))) return null;
  return [...new Set(parsed as string[])];
}

type ClientTemplate = { parameters?: Record<string, { defaultValue?: unknown } | undefined> };

/** A parameter's default value string in a client template, or undefined. */
export function clientTemplateString(template: ClientTemplate, key: string): string | undefined {
  const v = template.parameters?.[key]?.defaultValue as { value?: unknown } | undefined;
  return typeof v?.value === "string" ? v.value : undefined;
}

/** Pure: build the activity config from a client template (+ the server-side
 *  maintenance mirror, OR'd in so either source can raise it). */
export function buildActivityConfig(template: ClientTemplate, serverMaintenance = false): ActivityConfig {
  return {
    killed: clientTemplateFlag(template, KEY_KILL_SWITCH_ACTIVITY),
    maintenance: serverMaintenance || clientTemplateFlag(template, "maintenance_mode"),
    graceHours: sanitiseActivityGraceHours(clientTemplateString(template, KEY_ACTIVITY_GRACE_HOURS)),
    originAllowlist: parseOriginAllowlist(clientTemplateString(template, KEY_ACTIVITY_ORIGIN_ALLOWLIST)) ??
      [...DEFAULT_ACTIVITY_ORIGIN_ALLOWLIST],
    maxSessionsPerDay: MAX_ACTIVITY_SESSIONS_PER_DAY,
    maxRouteMPerDay: MAX_ACTIVITY_ROUTE_M_PER_DAY,
    maxClaimsPerDay: MAX_ACTIVITY_CLAIMS_PER_DAY,
  };
}

export type ActivityConfigLoader = () => Promise<ActivityConfig>;

/** Real loader. Never throws: a template read failure yields the fallback
 *  (feature on, defaults) — the same fail-open stance as getGameConfig. The
 *  ACTIVITY_CLAIMS_AUDIENCE env var remains the hard gate either way. */
async function loadActivityConfig(): Promise<ActivityConfig> {
  const serverMaintenance = (await getGameConfig()).maintenanceMode;
  try {
    const template = await admin.remoteConfig().getTemplate();
    return buildActivityConfig(template as unknown as ClientTemplate, serverMaintenance);
  } catch (e) {
    console.warn("[_activityConfig] client template read failed; using fallbacks:", e);
    return { ...FALLBACK_ACTIVITY_CONFIG, maintenance: serverMaintenance };
  }
}

const ACTIVITY_CONFIG_TTL_MS = 5 * 60 * 1000;
let loader: ActivityConfigLoader = loadActivityConfig;
let cache: { value: ActivityConfig; atMs: number } | null = null;

export async function getActivityConfig(nowMs: number = Date.now()): Promise<ActivityConfig> {
  if (cache && nowMs - cache.atMs < ACTIVITY_CONFIG_TTL_MS) return cache.value;
  const value = await loader();
  cache = { value, atMs: nowMs };
  return value;
}

/** Test hook: swap the loader and drop the cache. */
export function setActivityConfigLoaderForTest(l: ActivityConfigLoader | null): void {
  loader = l ?? loadActivityConfig;
  cache = null;
}

export type ActivityAudience = "admin" | "all" | "off";

/** Who may use workout claims, from the ACTIVITY_CLAIMS_AUDIENCE env var.
 *  Unset or unrecognised → "admin" (fails closed to the staff audience). */
export function activityClaimsAudience(
  env: Record<string, string | undefined> = process.env,
): ActivityAudience {
  const v = (env.ACTIVITY_CLAIMS_AUDIENCE ?? "").trim().toLowerCase();
  if (v === "all" || v === "off") return v;
  return "admin";
}

/** Whether a caller with [token] is inside [audience]. */
export function inActivityAudience(audience: ActivityAudience, token: { [claim: string]: unknown } | undefined): boolean {
  if (audience === "all") return true;
  if (audience === "off") return false;
  return token?.admin === true;
}

/**
 * Shared gate for both workout-claim callables: audience, kill switch, then
 * maintenance. The server-side maintenance check lives HERE, not in
 * _claimCore (MaintenanceGuard is client-only, and the core is pinned free of
 * maintenance logic by cross_language_sync_test). Errors carry
 * `details.reason` for the client.
 */
export async function assertActivityClaimsOpen(
  token: { [claim: string]: unknown } | undefined,
  env: Record<string, string | undefined> = process.env,
): Promise<ActivityConfig> {
  if (!inActivityAudience(activityClaimsAudience(env), token)) {
    throw new functions.https.HttpsError(
      "permission-denied", "Workout claims aren't available yet.", { reason: "not_available" });
  }
  const cfg = await getActivityConfig();
  if (cfg.killed) {
    throw new functions.https.HttpsError(
      "failed-precondition", "Workout claims are switched off for now.", { reason: "not_available" });
  }
  if (cfg.maintenance) {
    throw new functions.https.HttpsError(
      "unavailable", "We're doing a spot of maintenance. Try again shortly.", { reason: "maintenance" });
  }
  return cfg;
}
