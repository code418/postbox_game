// flushOfflineClaims — settle claims captured offline (ROADMAP v1.5, offline
// play Phases 2-3).
//
// Input: a batch of captures `{scanId, lat, lng, capturedAtMs}` plus the
// client wall-clock at flush time. Each capture carries the HMAC scan token
// its scan issued (see _scanToken.ts for the threat model); the server
// enforces the capture window against BOTH server-attested bounds, a
// proximity bound to the scanned position, monotonic ordering, a per-user
// daily quota, the Remote Config kill switch, and a server-side maintenance
// re-check (MaintenanceGuard is client-only). Items are adjudicated
// SEQUENTIALLY through scoreClaimAt so earlier claims are visible to later
// items' travel-speed neighbour queries — allSettled across items would skip
// the chain validation entirely.
//
// Per-item results are returned so the client can reconcile honestly:
// [{ok, claimed, points, dailyDate, reason?}].

import "./adminInit";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import * as geolib from "geolib";
import { getGameConfig } from "./_config";
import { getLondonDayOf, getTodayLondon } from "./_dateUtils";
import { scoreClaimAt } from "./_claimCore";
import { requireAppCheck } from "./_appCheck";
import { validateAttemptId, beginAttempt, completeAttempt, failAttempt, attemptDecisionToAction } from "./_attempts";
import { defineSecret } from "firebase-functions/params";
import { getScanSecret, verifyScanToken, ScanTokenPayload, SCAN_SECRET_ENV } from "./_scanToken";
import { QuotaState } from "./reports";

/** Secret Manager binding so process.env carries the HMAC secret at runtime. */
const scanSecret = defineSecret(SCAN_SECRET_ENV);

const database = admin.firestore();

/** Hard cap on captures per flush call. */
export const MAX_FLUSH_BATCH = 20;

/** How far a capture may sit from its token's scan position. Generous vs the
 *  claim radius (30 m): GPS drift plus a short wander are fine; a different
 *  street corner is not. The server remains the judge of what's in range —
 *  scoreClaimAt re-runs the radius lookup regardless. */
export const MAX_SCAN_DISTANCE_M = 250;

export interface FlushItem {
  scanId: string;
  lat: number;
  lng: number;
  capturedAtMs: number;
}

export interface FlushItemVerdict {
  ok: boolean;
  reason?: string;
  /** The verified token payload, present when ok. */
  token?: ScanTokenPayload;
}

/**
 * Pure pre-checks for a flush batch (exported for unit tests). Token
 * verification is injected so tests need no secret plumbing. Order of
 * precedence per item: bad_token → before_scan → future_capture → expired →
 * too_far_from_scan → non_monotonic.
 */
export function validateFlushBatch(
  items: FlushItem[],
  ctx: {
    uid: string;
    nowMs: number;
    graceMs: number;
    verifyToken: (token: string) => ScanTokenPayload | null;
  },
): FlushItemVerdict[] {
  let prevCapturedAtMs: number | undefined;
  return items.map((item) => {
    const token = ctx.verifyToken(item.scanId);
    if (!token) return { ok: false, reason: "bad_token" };
    if (item.capturedAtMs < token.issuedAtMs) {
      return { ok: false, reason: "before_scan" };
    }
    if (item.capturedAtMs > ctx.nowMs) {
      return { ok: false, reason: "future_capture" };
    }
    if (ctx.nowMs - item.capturedAtMs > ctx.graceMs) {
      return { ok: false, reason: "expired" };
    }
    const distance = geolib.getDistance(
      { latitude: token.lat, longitude: token.lng },
      { latitude: item.lat, longitude: item.lng },
    );
    if (distance > MAX_SCAN_DISTANCE_M) {
      return { ok: false, reason: "too_far_from_scan" };
    }
    // Batch-level: capture times must be non-decreasing. An out-of-order
    // batch indicates a tampered outbox (the client always appends in
    // monotonic capture order).
    if (prevCapturedAtMs !== undefined && item.capturedAtMs < prevCapturedAtMs) {
      return { ok: false, reason: "non_monotonic" };
    }
    prevCapturedAtMs = item.capturedAtMs;
    return { ok: true, token };
  });
}

/**
 * Pure quota step (exported for unit tests): grant up to [requested] slots
 * from a per-day cap of [max]. Same date-rollover semantics as reports.ts's
 * nextQuotaState, but granting a COUNT (partial grants allowed) rather than a
 * single slot.
 */
export function nextQuotaStateBy(
  current: QuotaState | undefined,
  today: string,
  max: number,
  requested: number,
): { allowed: number; state: QuotaState } {
  const priorRaw = current?.date === today ? current.count : 0;
  const prior = Number.isFinite(priorRaw) && priorRaw > 0 ? Math.floor(priorRaw) : 0;
  const allowed = Math.max(0, Math.min(requested, max - prior));
  return { allowed, state: { date: today, count: prior + allowed } };
}

interface FlushCallData {
  flushClientTsMs?: unknown;
  attemptId?: unknown;
  claims?: unknown;
}

export const flushOfflineClaims = functions.https.onCall(
  { enforceAppCheck: true, secrets: [scanSecret] },
  async (request) => {
    requireAppCheck(request);
    const uid = request.auth?.uid;
    if (!uid) {
      throw new functions.https.HttpsError("unauthenticated", "Must be signed in to post claims");
    }

    const { flushClientTsMs, attemptId, claims } = (request.data as FlushCallData) ?? {};
    if (flushClientTsMs !== undefined &&
        (typeof flushClientTsMs !== "number" || !Number.isFinite(flushClientTsMs))) {
      throw new functions.https.HttpsError("invalid-argument", "flushClientTsMs must be a finite number when provided");
    }
    validateAttemptId(attemptId);
    if (!Array.isArray(claims) || claims.length === 0 || claims.length > MAX_FLUSH_BATCH) {
      throw new functions.https.HttpsError(
        "invalid-argument", `claims must be a non-empty array of at most ${MAX_FLUSH_BATCH} items`);
    }
    const items: FlushItem[] = claims.map((c) => {
      const item = c as Record<string, unknown>;
      const scanId = item?.scanId;
      const lat = item?.lat;
      const lng = item?.lng;
      const capturedAtMs = item?.capturedAtMs;
      if (typeof scanId !== "string" || scanId.length === 0 || scanId.length > 2048 ||
          typeof lat !== "number" || !Number.isFinite(lat) || lat < -90 || lat > 90 ||
          typeof lng !== "number" || !Number.isFinite(lng) || lng < -180 || lng > 180 ||
          typeof capturedAtMs !== "number" || !Number.isFinite(capturedAtMs)) {
        throw new functions.https.HttpsError("invalid-argument", "each claim needs scanId, lat, lng, capturedAtMs");
      }
      return { scanId, lat, lng, capturedAtMs };
    });

    const config = await getGameConfig();
    if (config.offlineClaimsKilled) {
      throw new functions.https.HttpsError(
        "failed-precondition", "Offline claims are temporarily disabled. Your captures are kept — try again later.");
    }
    // MaintenanceGuard is client-only; an offline user can queue during
    // maintenance and flush into a mid-migration server without this.
    if (config.maintenanceMode) {
      throw new functions.https.HttpsError(
        "unavailable", "We're doing a spot of maintenance. Your captures are kept — try again shortly.");
    }

    const secret = getScanSecret();
    if (!secret) {
      // Fail closed: without the secret nothing can be verified.
      console.error("[flushOfflineClaims] OFFLINE_SCAN_SECRET not configured");
      throw new functions.https.HttpsError("failed-precondition", "Offline claims are not available right now.");
    }

    // Idempotent envelope: a retried flush (same attemptId) replays the whole
    // stored response instead of re-adjudicating — quota is not double-spent.
    if (typeof attemptId === "string") {
      const action = attemptDecisionToAction(await beginAttempt(database, attemptId, uid));
      if (action) return action.replay;
      try {
        const response = await runFlush(uid, items, flushClientTsMs as number | undefined, secret, config.offlineGraceHours, config.maxOfflineClaimsPerDay);
        await completeAttempt(database, attemptId, uid, response);
        return response;
      } catch (e) {
        await failAttempt(database, attemptId);
        throw e;
      }
    }
    return runFlush(uid, items, flushClientTsMs as number | undefined, secret, config.offlineGraceHours, config.maxOfflineClaimsPerDay);
  },
);

async function runFlush(
  uid: string,
  items: FlushItem[],
  flushClientTsMs: number | undefined,
  secret: string,
  graceHours: number,
  maxPerDay: number,
): Promise<Record<string, unknown>> {
  const nowMs = Date.now();
  const verdicts = validateFlushBatch(items, {
    uid,
    nowMs,
    graceMs: graceHours * 3600_000,
    verifyToken: (t) => verifyScanToken(t, uid, secret),
  });

  // Reserve quota slots for the pre-check-passing items (transactional
  // counter, same pattern as reportQuotas). Partial grants: items beyond the
  // remaining quota get quota_exceeded verdicts, never a thrown error — the
  // client must learn the per-item outcomes.
  const eligible = verdicts.filter((v) => v.ok).length;
  const today = getTodayLondon();
  let granted = 0;
  if (eligible > 0) {
    const quotaRef = database.collection("offlineFlushQuotas").doc(uid);
    granted = await database.runTransaction(async (tx) => {
      const snap = await tx.get(quotaRef);
      const r = nextQuotaStateBy(snap.data() as QuotaState | undefined, today, maxPerDay, eligible);
      tx.set(quotaRef, r.state, { merge: false });
      return r.allowed;
    });
  }

  const batchTimes = items.map((i) => i.capturedAtMs);
  const batchSpanMs = batchTimes.length > 1
    ? Math.max(...batchTimes) - Math.min(...batchTimes)
    : 0;

  // Sequential adjudication (NOT allSettled): each settled claim must be
  // visible to the next item's eventTime-neighbour travel check, or the
  // chain isn't validated at all.
  const results: Array<Record<string, unknown>> = [];
  let grantsLeft = granted;
  /* eslint-disable no-await-in-loop */
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    const verdict = verdicts[i];
    if (!verdict.ok) {
      results.push({ ok: false, reason: verdict.reason });
      continue;
    }
    if (grantsLeft <= 0) {
      results.push({ ok: false, reason: "quota_exceeded" });
      continue;
    }
    grantsLeft--;
    try {
      const outcome = await scoreClaimAt(uid, item.lat, item.lng, {
        eventTimeMs: item.capturedAtMs,
        claimDate: getLondonDayOf(new Date(item.capturedAtMs)),
        offline: {
          queuedForMs: nowMs - item.capturedAtMs,
          batchSize: items.length,
          batchSpanMs,
          flushClientTsMs,
        },
      });
      results.push({ ok: true, ...outcome });
    } catch (e) {
      const code = (e as { code?: string }).code;
      results.push({
        ok: false,
        reason: code === "failed-precondition" ? "too_fast" : "error",
      });
    }
  }
  /* eslint-enable no-await-in-loop */

  const totalPoints = results.reduce(
    (s, r) => s + (r.ok === true && typeof r.points === "number" ? r.points : 0), 0);
  const totalClaimed = results.reduce(
    (s, r) => s + (r.ok === true && typeof r.claimed === "number" ? r.claimed : 0), 0);
  return { results, totalClaimed, totalPoints };
}
