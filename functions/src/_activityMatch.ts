// Source-agnostic workout-route matching (IO layer over _routeMatch.ts).
//
// Health Connect submissions arrive through the matchActivityRoute callable;
// future server-side sources (a Strava / Google Health API webhook) would
// build the same RouteSubmission and call prepareRoute + findCandidates.
//
// PRIVACY: the route is processed in memory and never stored or logged. What
// leaves this module is a list of candidate groups — a signed token, the pass
// time, and per-box monarch + points for the quiz. No box coordinates.

import type { firestore } from "firebase-admin";
import * as functions from "firebase-functions";
import { GameConfig, resolvePointsForMonarch } from "./_config";
import {
  ActivityConfig,
  ELIGIBLE_EXERCISE_TYPES,
  EligibleExerciseType,
} from "./_activityConfig";
import {
  ActivityRecordingMethod,
  ActivitySource,
  ACTIVITY_SOURCES,
  candidateKey,
  sessionFingerprint,
  signActivityCandidate,
} from "./_activityToken";
import {
  coveringCells,
  defaultRouteLimits,
  groupPasses,
  matchRoute,
  routeDigest,
  RoutePoint,
  validateRoute,
  RouteRejectReason,
} from "./_routeMatch";
import { queryPostboxesInCells } from "./_postboxQuery";

/** Cap on candidate groups returned for one session. */
export const MAX_CANDIDATES_PER_SESSION = 60;

/** Max length of a source session id (Health Connect ids are UUIDs). */
export const MAX_SESSION_ID_LEN = 64;

export type SubmittedRecordingMethod = ActivityRecordingMethod | "manual";

/** A recorded workout route, normalised across sources. */
export interface RouteSubmission {
  source: ActivitySource;
  sessionId: string;
  originPackage: string;
  recordingMethod: SubmittedRecordingMethod;
  exerciseType: string;
  startMs: number;
  endMs: number;
  points: RoutePoint[];
}

/** One claimable candidate as returned to the client. */
export interface ActivityCandidateDto {
  token: string;
  key: string;
  passedAtMs: number;
  claimDate: string;
  boxes: Array<{ monarch?: string; points: number }>;
}

/** Per-session verdicts returned (not thrown) so the client can cache them
 *  against the session's id@lastModified and never resubmit. */
export type SessionRejectReason =
  | "manual_entry"
  | "origin_not_supported"
  | "exercise_type_not_supported"
  | RouteRejectReason
  | "route_too_large";

function bad(msg: string): never {
  throw new functions.https.HttpsError("invalid-argument", msg);
}

const finite = (x: unknown): x is number => typeof x === "number" && Number.isFinite(x);

/**
 * Validate the callable payload's SHAPE and normalise it to a RouteSubmission.
 * Throws invalid-argument on anything malformed. Semantic checks (allowlist,
 * session bounds, plausibility) are prepareRoute's job and come back as
 * verdicts, not errors.
 *
 * Wire format (compact parallel arrays, times relative to startMs):
 *   { source, session: {id, lastModifiedMs, exerciseType, originPackage,
 *     recordingMethod, startMs, endMs}, route: {dtMs[], lat[], lng[]} }
 */
export function validateActivitySubmission(data: unknown): RouteSubmission & { lastModifiedMs: number } {
  const d = (typeof data === "object" && data !== null ? data : {}) as Record<string, unknown>;
  if (!ACTIVITY_SOURCES.includes(d.source as ActivitySource)) bad("source must be a supported workout source");
  const s = (typeof d.session === "object" && d.session !== null ? d.session : null) as Record<string, unknown> | null;
  if (!s) bad("session is required");
  const id = s.id;
  if (typeof id !== "string" || id.length === 0 || id.length > MAX_SESSION_ID_LEN || !/^[A-Za-z0-9._:-]+$/.test(id)) {
    bad("session.id must be a short id string");
  }
  if (!finite(s.lastModifiedMs)) bad("session.lastModifiedMs must be a finite number");
  if (typeof s.exerciseType !== "string" || s.exerciseType.length === 0 || s.exerciseType.length > 32) {
    bad("session.exerciseType is required");
  }
  if (typeof s.originPackage !== "string" || s.originPackage.length === 0 || s.originPackage.length > 128) {
    bad("session.originPackage is required");
  }
  const rm = s.recordingMethod;
  if (rm !== "active" && rm !== "automatic" && rm !== "manual" && rm !== "unknown") {
    bad("session.recordingMethod must be active|automatic|manual|unknown");
  }
  if (!finite(s.startMs) || !finite(s.endMs)) bad("session.startMs/endMs must be finite numbers");

  const r = (typeof d.route === "object" && d.route !== null ? d.route : null) as Record<string, unknown> | null;
  if (!r) bad("route is required");
  const { dtMs, lat, lng } = r as { dtMs?: unknown; lat?: unknown; lng?: unknown };
  if (!Array.isArray(dtMs) || !Array.isArray(lat) || !Array.isArray(lng)) bad("route.dtMs/lat/lng must be arrays");
  if (dtMs.length !== lat.length || lat.length !== lng.length) bad("route arrays must be the same length");
  if (dtMs.length > 5000) bad("route has too many points");
  const start = s.startMs as number;
  const points: RoutePoint[] = [];
  for (let i = 0; i < dtMs.length; i++) {
    const t = dtMs[i];
    const la = lat[i];
    const ln = lng[i];
    if (!finite(t) || !finite(la) || !finite(ln)) bad("route values must be finite numbers");
    points.push({ tMs: start + t, lat: la, lng: ln });
  }
  return {
    source: d.source as ActivitySource,
    sessionId: id as string,
    lastModifiedMs: s.lastModifiedMs as number,
    originPackage: s.originPackage as string,
    recordingMethod: rm as SubmittedRecordingMethod,
    exerciseType: s.exerciseType as string,
    startMs: start,
    endMs: s.endMs as number,
    points,
  };
}

export type PreparedRoute =
  | { ok: true; usable: boolean[]; lengthM: number; digest: string }
  | { ok: false; reason: SessionRejectReason };

/** Pure semantic checks on a submission: recording method, origin allowlist,
 *  exercise type, then the route geometry checks. */
export function prepareRoute(sub: RouteSubmission, cfg: ActivityConfig, nowMs: number): PreparedRoute {
  if (sub.recordingMethod === "manual") return { ok: false, reason: "manual_entry" };
  if (!cfg.originAllowlist.includes(sub.originPackage)) return { ok: false, reason: "origin_not_supported" };
  if (!ELIGIBLE_EXERCISE_TYPES.includes(sub.exerciseType as EligibleExerciseType)) {
    return { ok: false, reason: "exercise_type_not_supported" };
  }
  const v = validateRoute(sub.points, sub, nowMs, defaultRouteLimits(cfg.graceHours * 3600_000));
  if (!v.ok) return v;
  return { ok: true, usable: v.usable, lengthM: v.lengthM, digest: routeDigest(sub.points) };
}

export type FindCandidatesResult =
  | {
      ok: true;
      candidates: ActivityCandidateDto[];
      alreadyClaimed: number;
      expiredPasses: number;
      truncated: boolean;
    }
  | { ok: false; reason: "route_too_large" };

/**
 * IO: fetch postboxes along a prepared route, match passes, drop those that
 * are past the claim window or that the user already claimed on the pass day,
 * group them into one-quiz candidates and sign a token for each.
 */
export async function findCandidates(
  db: firestore.Firestore,
  uid: string,
  sub: RouteSubmission,
  prepared: { usable: boolean[] },
  gameCfg: GameConfig,
  activityCfg: ActivityConfig,
  secret: string,
  nowMs: number,
): Promise<FindCandidatesResult> {
  const radiusM = gameCfg.claimRadiusMeters;
  const cellIndex = coveringCells(sub.points, prepared.usable, radiusM + 5);
  if (!cellIndex) return { ok: false, reason: "route_too_large" };

  const boxes = cellIndex.size > 0 ? await queryPostboxesInCells(db, [...cellIndex.keys()]) : [];
  const graceMs = activityCfg.graceHours * 3600_000;
  let expiredPasses = 0;
  const live = matchRoute(sub.points, prepared.usable, boxes, radiusM, cellIndex).filter((p) => {
    if (nowMs - p.passedAtMs > graceMs) {
      expiredPasses++;
      return false;
    }
    return true;
  });

  // Drop boxes this user already claimed on the pass's day (≤ 2–3 days for a
  // ≤ 12 h route). Served by the same (userid, dailyDate) shape the claim
  // path's pre-fetch uses.
  const days = [...new Set(live.map((p) => p.claimDate))];
  const claimed = new Set<string>();
  if (days.length > 0) {
    const snap = await db.collection("claims")
      .where("userid", "==", uid)
      .where("dailyDate", "in", days)
      .get();
    for (const doc of snap.docs) {
      const ref = doc.data().postboxes as string | undefined;
      const day = doc.data().dailyDate as string | undefined;
      if (typeof ref === "string" && typeof day === "string") {
        claimed.add(`${ref.replace(/^\/postbox\//, "")}|${day}`);
      }
    }
  }
  let alreadyClaimed = 0;
  const open = live.filter((p) => {
    if (claimed.has(`${p.boxId}|${p.claimDate}`)) {
      alreadyClaimed++;
      return false;
    }
    return true;
  });

  const groups = groupPasses(open, radiusM);
  const truncated = groups.length > MAX_CANDIDATES_PER_SESSION;
  const sessionFp = sessionFingerprint(sub.sessionId, secret);
  const rm: ActivityRecordingMethod = sub.recordingMethod === "manual" ? "unknown" : sub.recordingMethod;
  const candidates = groups.slice(0, MAX_CANDIDATES_PER_SESSION).map((g) => ({
    token: signActivityCandidate({
      uid,
      boxIds: g.boxIds,
      lat: g.anchor.lat,
      lng: g.anchor.lng,
      passedAtMs: g.passedAtMs,
      claimDate: g.claimDate,
      sessionFp,
      source: sub.source,
      origin: sub.originPackage,
      rm,
      issuedAtMs: nowMs,
    }, secret),
    key: candidateKey(uid, g.boxIds, g.claimDate, secret),
    passedAtMs: g.passedAtMs,
    claimDate: g.claimDate,
    boxes: g.monarchs.map((m) => ({
      ...(m !== undefined ? { monarch: m } : {}),
      points: resolvePointsForMonarch(gameCfg, m),
    })),
  }));
  return { ok: true, candidates, alreadyClaimed, expiredPasses, truncated };
}
