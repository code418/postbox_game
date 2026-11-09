// Workout-claim candidate tokens.
//
// matchActivityRoute signs one token per candidate group (the boxes a recorded
// route passed together); claimActivityPostbox accepts nothing else. The token
// is what stops a client claiming a box its route never passed, or at a time
// or day it didn't pass it: the server computed the anchor, pass time and box
// ids, and the client can only hand them back.
//
// Signed with a key derived from OFFLINE_SCAN_SECRET for the
// "activity-candidate" domain (see _scanToken.ts), so a candidate token can
// never pass as an offline scanId and vice versa. The payload is readable
// base64 JSON: box ids are already public (OSM node ids, returned by
// nearbyPostboxes) and the anchor is a point on the user's own route.

import { randomBytes } from "crypto";
import { domainDigest, signDomainToken, verifyDomainToken } from "./_scanToken";

export const ACTIVITY_TOKEN_VERSION = 1;

/** Where the route came from. Only Health Connect exists today; the field is
 *  here so server-side sources (Strava, Google Health API, HealthKit) can
 *  reuse the token unchanged. */
export type ActivitySource = "health_connect";
export const ACTIVITY_SOURCES: readonly ActivitySource[] = ["health_connect"];

/** Normalised recording method (Health Connect Metadata.recordingMethod). */
export type ActivityRecordingMethod = "active" | "automatic" | "unknown";

export interface ActivityCandidatePayload {
  v: number;
  d: "activity-candidate";
  uid: string;
  boxIds: string[];
  /** The claim anchor: the route point closest to the group's first box. */
  lat: number;
  lng: number;
  passedAtMs: number;
  /** London day of passedAtMs. */
  claimDate: string;
  /** Keyed fingerprint of the source session id (not uid-salted, so the same
   *  run claimed by two accounts is detectable). */
  sessionFp: string;
  source: ActivitySource;
  /** Package name of the app that recorded the workout. */
  origin: string;
  rm: ActivityRecordingMethod;
  issuedAtMs: number;
  nonce: string;
}

/** Fingerprint of a source session id. */
export function sessionFingerprint(sessionId: string, secret: string): string {
  return domainDigest(sessionId, secret, "activity-session-fp", 22);
}

/** Opaque per-user key for a (box set, day) — lets the client de-duplicate the
 *  same boxes surfaced by two sessions on one day without learning which boxes
 *  they are from the key itself. */
export function candidateKey(uid: string, boxIds: string[], claimDate: string, secret: string): string {
  return domainDigest(`${uid}|${[...boxIds].sort().join(",")}|${claimDate}`, secret, "activity-candidate-key", 16);
}

export function signActivityCandidate(
  payload: Omit<ActivityCandidatePayload, "v" | "d" | "nonce"> & { nonce?: string },
  secret: string,
): string {
  const full: ActivityCandidatePayload = {
    v: ACTIVITY_TOKEN_VERSION,
    d: "activity-candidate",
    ...payload,
    nonce: payload.nonce ?? randomBytes(8).toString("base64url"),
  };
  return signDomainToken(full, secret, "activity-candidate");
}

const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;

/** Verify a candidate token for [uid]. Returns the payload or null on ANY
 *  failure (bad signature, wrong domain, wrong user, malformed field). Window
 *  checks (expiry, day consistency) are the caller's, since they need "now". */
export function verifyActivityCandidate(
  token: unknown,
  uid: string,
  secret: string,
): ActivityCandidatePayload | null {
  if (typeof token !== "string" || token.length === 0 || token.length > 8192) return null;
  const p = verifyDomainToken(token, secret, "activity-candidate");
  if (!p) return null;
  const finite = (x: unknown): x is number => typeof x === "number" && Number.isFinite(x);
  if (
    p.v !== ACTIVITY_TOKEN_VERSION ||
    p.uid !== uid ||
    !Array.isArray(p.boxIds) || p.boxIds.length === 0 || p.boxIds.length > 20 ||
    !p.boxIds.every((b) => typeof b === "string" && b.length > 0 && b.length <= 128 && !b.includes("/")) ||
    !finite(p.lat) || p.lat < -90 || p.lat > 90 ||
    !finite(p.lng) || p.lng < -180 || p.lng > 180 ||
    !finite(p.passedAtMs) ||
    typeof p.claimDate !== "string" || !DAY_RE.test(p.claimDate) ||
    typeof p.sessionFp !== "string" || p.sessionFp.length === 0 ||
    !ACTIVITY_SOURCES.includes(p.source as ActivitySource) ||
    typeof p.origin !== "string" || p.origin.length === 0 || p.origin.length > 128 ||
    (p.rm !== "active" && p.rm !== "automatic" && p.rm !== "unknown") ||
    !finite(p.issuedAtMs) ||
    typeof p.nonce !== "string"
  ) {
    return null;
  }
  return p as unknown as ActivityCandidatePayload;
}
