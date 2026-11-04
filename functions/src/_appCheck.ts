// App Check enforcement helpers (ROADMAP v1.5 — server-side App Check).
//
// Two layers:
//   1. Platform: `enforceAppCheck: true` in the callable's options makes the
//      Functions front-end reject unattested requests before our code runs.
//   2. In-code (this module): defence-in-depth for paths the platform layer
//      doesn't cover (misconfiguration, emulators, test wrappers) — and the
//      only layer that offers a break-glass during App Check provider outages.
//
// requireAppCheck — hard reject (the claim path: startScoring, nearbyPostboxes,
// flushOfflineClaims). monitorAppCheck — log-only for every other callable
// while the 7-day monitor window runs; flipping one to enforce is a one-line
// change from monitorAppCheck to requireAppCheck.
//
// Break-glass: set the APP_CHECK_BREAK_GLASS env var to exactly "1" on the
// affected functions to temporarily allow tokenless requests through the
// in-code check (platform enforcement must be toggled in the console). Every
// bypassed request is logged loudly so the window is auditable.

import * as functions from "firebase-functions";

/** Env var that disables the in-code hard check when set to exactly "1". */
export const BREAK_GLASS_ENV = "APP_CHECK_BREAK_GLASS";

/** The slice of a CallableRequest this module inspects. `app` is populated by
 *  the Functions SDK only when the request carried a valid App Check token. */
export interface AppCheckable {
  app?: unknown;
}

/** Reject the request with `failed-precondition` when it carries no verified
 *  App Check app, unless the break-glass env var is active. `env` is
 *  injectable for tests; production uses process.env. */
export function requireAppCheck(
  request: AppCheckable,
  env: Record<string, string | undefined> = process.env,
): void {
  if (request.app) return;
  if (env[BREAK_GLASS_ENV] === "1") {
    console.warn(
      "[appCheck] BREAK GLASS ACTIVE — tokenless request allowed through the in-code check",
    );
    return;
  }
  throw new functions.https.HttpsError(
    "failed-precondition",
    "App attestation failed. Please update the app and try again.",
  );
}

/** Monitor mode: never rejects, just logs unattested requests so the console
 *  denial-rate dashboards can be sanity-checked against our own numbers before
 *  enforcement is widened beyond the claim path. */
export function monitorAppCheck(request: AppCheckable, callableName: string): void {
  if (!request.app) {
    console.warn(`[appCheck:monitor] ${callableName} called without an App Check token`);
  }
}
