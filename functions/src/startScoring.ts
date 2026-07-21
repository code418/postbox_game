import "./adminInit";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import { DEFAULT_CLAIM_RADIUS_METERS } from "./_config";
import { scoreClaimAt } from "./_claimCore";
import { requireAppCheck } from "./_appCheck";
import { validateAttemptId, beginAttempt, completeAttempt, failAttempt, attemptDecisionToAction } from "./_attempts";

// The scoring write path itself lives in _claimCore.ts (scoreClaimAt), shared
// with the offline flushOfflineClaims callable — this module is the live
// wrapper: validation, App Check, and the attempts idempotency envelope.
// dailyClaimPatch's canonical definition moved with the core; re-exported here
// for the unit test that pins its no-uid privacy property.
export { dailyClaimPatch } from "./_claimCore";

const database = admin.firestore();

/** Fallback radius (metres) within which a user must stand to claim a postbox.
 *  The live value comes from Remote Config via _config.ts (getClaimRadiusMeters);
 *  this constant is only the documented fallback. Must match
 *  AppPreferences.claimRadiusMeters in lib/app_preferences.dart (pinned by
 *  test/cross_language_sync_test.dart) and DEFAULT_CLAIM_RADIUS_METERS.
 *  DELIBERATELY declared here (not in _claimCore.ts): the cross-language sync
 *  test regexes THIS file for the literal. */
const CLAIM_RADIUS_METERS = 30;

// The documented fallback here must equal _config's fallback, since the
// cross-language sync test pins THIS constant against the Dart client while the
// runtime radius actually resolves through _config. (Same load-time-invariant
// pattern as _abuseSignals.ts.)
if (CLAIM_RADIUS_METERS !== DEFAULT_CLAIM_RADIUS_METERS) {
  throw new Error("CLAIM_RADIUS_METERS must equal DEFAULT_CLAIM_RADIUS_METERS in _config.ts");
}

interface StartScoringCallData {
  lat?: number;
  lng?: number;
  /** Client wall-clock at claim time (ms since epoch). Optional — legacy/web
   *  clients omit it. Stored for the shadow-mode out-of-window anomaly signal. */
  clientTsMs?: number;
  /** Random 256-bit per-install token (64 hex chars), generated and persisted
   *  by lib/services/device_id_service.dart — deliberately NOT derived from
   *  hardware or any Firebase id. Optional — legacy/web clients omit it. Stored
   *  for the shadow-mode repeated-device signal (one install claiming across
   *  many accounts). Treated as PII: stripped on account deletion
   *  (_accountDeletion.ts) and by the 90-day retention sweep (dataRetention.ts). */
  deviceIdHash?: string;
  /** Client-generated UUID identifying this logical claim attempt. A retry
   *  (same id) replays the stored response instead of re-running the scoring
   *  path — see _attempts.ts. Optional; legacy clients omit it. */
  attemptId?: string;
}

/** Max stored length of a device-id hash (SHA-256 hex is 64 chars; allow slack). */
const MAX_DEVICE_ID_HASH_LEN = 128;

export const startScoring = functions.https.onCall({ enforceAppCheck: true }, async (request) => {
  // Platform enforceAppCheck rejects unattested requests up front; this
  // in-code check is the defence-in-depth + break-glass layer (see _appCheck).
  requireAppCheck(request);
  const userid = request.auth?.uid;
  if (!userid) {
    throw new functions.https.HttpsError("unauthenticated", "Must be signed in to claim a postbox");
  }

  const { lat, lng, clientTsMs, deviceIdHash, attemptId } = (request.data as StartScoringCallData) ?? {};
  if (lat === undefined || lat === null || lng === undefined || lng === null) {
    throw new functions.https.HttpsError("invalid-argument", "lat and lng are required");
  }
  if (!Number.isFinite(lat) || lat < -90 || lat > 90) {
    throw new functions.https.HttpsError("invalid-argument", "lat must be a finite number between -90 and 90");
  }
  if (!Number.isFinite(lng) || lng < -180 || lng > 180) {
    throw new functions.https.HttpsError("invalid-argument", "lng must be a finite number between -180 and 180");
  }
  if (clientTsMs !== undefined && (typeof clientTsMs !== "number" || !Number.isFinite(clientTsMs))) {
    throw new functions.https.HttpsError("invalid-argument", "clientTsMs must be a finite number when provided");
  }
  if (deviceIdHash !== undefined &&
      (typeof deviceIdHash !== "string" || deviceIdHash.length === 0 || deviceIdHash.length > MAX_DEVICE_ID_HASH_LEN)) {
    throw new functions.https.HttpsError("invalid-argument", "deviceIdHash must be a non-empty string when provided");
  }
  validateAttemptId(attemptId);

  // Idempotent replay (v1.5, offline play Phase 1): a retry carrying the same
  // attemptId gets its original response verbatim instead of falling into the
  // already-claimed fast-path with zero points — the lost-claim bug. Legacy
  // clients omit attemptId and take the direct path unchanged.
  if (attemptId !== undefined) {
    const action = attemptDecisionToAction(await beginAttempt(database, attemptId, userid));
    if (action) return action.replay;
    try {
      const response = await scoreClaimAt(userid, lat, lng, { clientTsMs, deviceIdHash });
      await completeAttempt(database, attemptId, userid, response);
      return response;
    } catch (e) {
      await failAttempt(database, attemptId);
      throw e;
    }
  }
  return scoreClaimAt(userid, lat, lng, { clientTsMs, deviceIdHash });
});
