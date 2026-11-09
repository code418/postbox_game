// matchActivityRoute — find the postboxes a recorded workout route passed.
//
// The client (Health Connect bridge) submits one walking/running/hiking
// session's GPS route; the server returns signed candidates the player can
// then claim via claimActivityPostbox after the cypher quiz. The route is
// processed in memory and never stored or logged (see _activityMatch.ts).
//
// Gates, in order: App Check → auth → audience (ACTIVITY_CLAIMS_AUDIENCE env)
// → kill switch → maintenance → payload shape → per-session verdicts → daily
// budget → match. Per-session verdicts (manual entry, unsupported app,
// expired, implausible speed …) are RETURNED, not thrown, so the client can
// cache them; budget exhaustion is THROWN (resource-exhausted) so it is never
// cached as a verdict.
//
// No attempts envelope: matching only reads and does idempotent quota
// bookkeeping (an unchanged route re-matches free), so a plain retry is safe
// and no route-derived points sit in attempts/ for 48 h.

import "./adminInit";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import { defineSecret } from "firebase-functions/params";
import { requireAppCheck } from "./_appCheck";
import { getGameConfig } from "./_config";
import { getTodayLondon } from "./_dateUtils";
import { getScanSecret, SCAN_SECRET_ENV } from "./_scanToken";
import { assertActivityClaimsOpen } from "./_activityConfig";
import { nextMatchQuota } from "./_activityQuota";
import { sessionFingerprint } from "./_activityToken";
import { findCandidates, prepareRoute, validateActivitySubmission } from "./_activityMatch";

const scanSecret = defineSecret(SCAN_SECRET_ENV);
const database = admin.firestore();

export const matchActivityRoute = functions.https.onCall(
  { enforceAppCheck: true, secrets: [scanSecret], timeoutSeconds: 60, memory: "512MiB" },
  async (request) => {
    requireAppCheck(request);
    const uid = request.auth?.uid;
    if (!uid) {
      throw new functions.https.HttpsError("unauthenticated", "Must be signed in to check a workout");
    }
    const activityCfg = await assertActivityClaimsOpen(request.auth?.token);
    const sub = validateActivitySubmission(request.data);

    const secret = getScanSecret();
    if (!secret) {
      console.error("[matchActivityRoute] OFFLINE_SCAN_SECRET not configured");
      throw new functions.https.HttpsError(
        "failed-precondition", "Workout claims are not available right now.", { reason: "not_available" });
    }

    const nowMs = Date.now();
    const prepared = prepareRoute(sub, activityCfg, nowMs);
    if (!prepared.ok) {
      console.log(`[matchActivityRoute] uid=${uid} verdict=${prepared.reason} origin=${sub.originPackage}`);
      return { ok: false, reason: prepared.reason };
    }

    // Daily budget (sessions + route km). An unchanged route re-matches free.
    const sessionFp = sessionFingerprint(sub.sessionId, secret);
    const today = getTodayLondon();
    const quotaRef = database.collection("activityQuotas").doc(uid);
    const quota = await database.runTransaction(async (tx) => {
      const snap = await tx.get(quotaRef);
      const r = nextMatchQuota(snap.data(), today, nowMs,
        { sessionFp, digest: prepared.digest, lengthM: prepared.lengthM },
        { maxSessions: activityCfg.maxSessionsPerDay, maxRouteM: activityCfg.maxRouteMPerDay });
      if (r.allowed && r.charged) tx.set(quotaRef, r.state, { merge: false });
      return r;
    });
    if (!quota.allowed) {
      throw new functions.https.HttpsError(
        "resource-exhausted", "That's enough workouts checked for today.", { reason: "quota_exceeded" });
    }

    const gameCfg = await getGameConfig();
    const t0 = Date.now();
    const result = await findCandidates(database, uid, sub, prepared, gameCfg, activityCfg, secret, nowMs);
    if (!result.ok) {
      console.log(`[matchActivityRoute] uid=${uid} verdict=${result.reason}`);
      return { ok: false, reason: result.reason };
    }
    // Counts only — never points or coordinates.
    console.log(
      `[matchActivityRoute] uid=${uid} origin=${sub.originPackage} points=${sub.points.length} ` +
      `km=${(prepared.lengthM / 1000).toFixed(1)} candidates=${result.candidates.length} ` +
      `alreadyClaimed=${result.alreadyClaimed} expired=${result.expiredPasses} ` +
      `charged=${quota.charged} ms=${Date.now() - t0}`,
    );
    return result;
  },
);
