// claimActivityPostbox — claim a postbox a recorded workout route passed.
//
// Takes a candidate token from matchActivityRoute (the client shows the
// cypher quiz first) and scores the claim through the shared core at the
// token's anchor, dated to the London day the route passed the box:
//   - same-day passes take the live path (streak increment, notifications);
//   - a pass from yesterday is a BACKDATED claim, exactly like an offline
//     flush: streak recomputed from claim days (so a run can save a streak),
//     weekly/monthly/lifetime/county credited, the closed daily board not;
//   - restrictToPostboxIds limits the claim to the boxes the token names, so
//     one quiz can't sweep up an un-quizzed neighbour.
//
// attemptId is REQUIRED (no legacy clients): a retry replays the stored
// response. Quota exhaustion is THROWN inside the envelope, so the attempt is
// cleared rather than replaying "quota exceeded" for 48 h.

import "./adminInit";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import { defineSecret } from "firebase-functions/params";
import { requireAppCheck } from "./_appCheck";
import { validateAttemptId, runInAttempt } from "./_attempts";
import { scoreClaimAt } from "./_claimCore";
import { getLondonDayOf, getTodayLondon } from "./_dateUtils";
import { getScanSecret, SCAN_SECRET_ENV } from "./_scanToken";
import { ActivityCandidatePayload, verifyActivityCandidate } from "./_activityToken";
import { nextClaimQuota } from "./_activityQuota";
import { assertActivityClaimsOpen } from "./_activityConfig";

const scanSecret = defineSecret(SCAN_SECRET_ENV);
const database = admin.firestore();

/** Candidate tokens older than this are refused even inside the claim window
 *  (re-matching the route is free and issues fresh ones). */
export const MAX_TOKEN_AGE_MS = 48 * 60 * 60 * 1000;
/** Clock-skew tolerance for a pass time slightly in the future. */
const FUTURE_SLACK_MS = 5 * 60_000;
const MAX_DEVICE_ID_HASH_LEN = 128;

/** Pure window checks on a verified token. Returns a reason or null. */
export function checkCandidateWindow(
  t: ActivityCandidatePayload,
  nowMs: number,
  graceMs: number,
): "expired" | "bad_token" | "stale_token" | null {
  if (t.claimDate !== getLondonDayOf(new Date(t.passedAtMs))) return "bad_token";
  if (t.passedAtMs > nowMs + FUTURE_SLACK_MS || t.issuedAtMs > nowMs + FUTURE_SLACK_MS) return "bad_token";
  if (nowMs - t.passedAtMs > graceMs) return "expired";
  if (nowMs - t.issuedAtMs > MAX_TOKEN_AGE_MS) return "stale_token";
  return null;
}

interface ClaimActivityCallData {
  token?: unknown;
  attemptId?: unknown;
  clientTsMs?: unknown;
  deviceIdHash?: unknown;
}

export const claimActivityPostbox = functions.https.onCall(
  { enforceAppCheck: true, secrets: [scanSecret] },
  async (request) => {
    requireAppCheck(request);
    const uid = request.auth?.uid;
    if (!uid) {
      throw new functions.https.HttpsError("unauthenticated", "Must be signed in to claim a postbox");
    }
    const activityCfg = await assertActivityClaimsOpen(request.auth?.token);

    const { token, attemptId, clientTsMs, deviceIdHash } = (request.data as ClaimActivityCallData) ?? {};
    validateAttemptId(attemptId);
    if (attemptId === undefined) {
      throw new functions.https.HttpsError("invalid-argument", "attemptId is required");
    }
    if (clientTsMs !== undefined && (typeof clientTsMs !== "number" || !Number.isFinite(clientTsMs))) {
      throw new functions.https.HttpsError("invalid-argument", "clientTsMs must be a finite number when provided");
    }
    if (deviceIdHash !== undefined &&
        (typeof deviceIdHash !== "string" || deviceIdHash.length === 0 || deviceIdHash.length > MAX_DEVICE_ID_HASH_LEN)) {
      throw new functions.https.HttpsError("invalid-argument", "deviceIdHash must be a non-empty string when provided");
    }

    const secret = getScanSecret();
    if (!secret) {
      console.error("[claimActivityPostbox] OFFLINE_SCAN_SECRET not configured");
      throw new functions.https.HttpsError(
        "failed-precondition", "Workout claims are not available right now.", { reason: "not_available" });
    }
    const t = verifyActivityCandidate(token, uid, secret);
    if (!t) {
      throw new functions.https.HttpsError(
        "failed-precondition", "That workout candidate isn't valid any more.", { reason: "bad_token" });
    }
    const nowMs = Date.now();
    const windowReason = checkCandidateWindow(t, nowMs, activityCfg.graceHours * 3600_000);
    if (windowReason) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        windowReason === "expired"
          ? "That pass is too long ago to claim now."
          : "That workout candidate isn't valid any more.",
        { reason: windowReason });
    }

    return runInAttempt(database, attemptId, uid, async () => {
      const today = getTodayLondon();
      const quotaRef = database.collection("activityQuotas").doc(uid);
      const allowed = await database.runTransaction(async (tx) => {
        const snap = await tx.get(quotaRef);
        const r = nextClaimQuota(snap.data(), today, nowMs, activityCfg.maxClaimsPerDay);
        if (r.allowed) tx.set(quotaRef, r.state, { merge: false });
        return r.allowed;
      });
      if (!allowed) {
        throw new functions.https.HttpsError(
          "resource-exhausted", "That's the most workout claims for today.", { reason: "quota_exceeded" });
      }
      return scoreClaimAt(uid, t.lat, t.lng, {
        eventTimeMs: t.passedAtMs,
        claimDate: t.claimDate,
        clientTsMs: clientTsMs as number | undefined,
        deviceIdHash: deviceIdHash as string | undefined,
        restrictToPostboxIds: t.boxIds,
        activity: {
          source: t.source,
          origin: t.origin,
          recordingMethod: t.rm,
          sessionFp: t.sessionFp,
          lagMs: Math.max(0, nowMs - t.passedAtMs),
        },
      });
    });
  },
);
