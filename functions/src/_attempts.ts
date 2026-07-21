// Idempotent claim attempts (ROADMAP v1.5, offline play Phase 1).
//
// The claim WRITE has always been idempotent (deterministic claim doc IDs);
// the claim RESPONSE was not: if the network drops the response, the client's
// retry hits startScoring's already-claimed fast-path and renders an empty
// state — the player earned points they never saw. The fix is an
// `attempts/{attemptId}` doc keyed by a client-generated UUID: the first
// request stores its full response under the id, and any retry with the same
// id gets that response replayed verbatim.
//
// Chosen over a claims-collection query on retry because (a) a query-based
// replay double-credits across a London-midnight boundary, and (b) zero-claim
// responses (`found: false` / `allClaimedToday`) write no claim doc at all yet
// are exactly the responses worth replaying. One doc read by ID, no index.
//
// Lifecycle: begin (tx: replay | in_progress | proceed-and-mark) → handler
// runs → complete (store result, stamp TTL) or fail (delete marker so an
// immediate retry isn't blocked). Firestore native TTL on `expiresAt` reaps
// finished docs (deploy step: `gcloud firestore fields ttls update expiresAt
// --collection-group=attempts --enable-ttl`).

import * as admin from "firebase-admin";
import * as functions from "firebase-functions";

type Firestore = admin.firestore.Firestore;

/** A fresh `in_progress` marker younger than this blocks concurrent duplicates
 *  (`aborted`); older markers are presumed crashed and retaken. */
export const ATTEMPT_IN_PROGRESS_STALE_MS = 60_000;

/** How long a completed attempt stays replayable. Outlives any plausible
 *  client retry window (and the offline outbox's grace period is enforced
 *  separately server-side). */
export const ATTEMPT_TTL_MS = 48 * 60 * 60 * 1000;

/** Client-generated ids are UUIDs (36 chars); allow slack, forbid path chars. */
export const MAX_ATTEMPT_ID_LEN = 128;

export interface AttemptDoc {
  uid: string;
  status: "in_progress" | "done";
  result?: unknown;
  createdAtMs: number;
}

export type AttemptDecision =
  | { kind: "proceed" }
  | { kind: "replay"; result: unknown }
  | { kind: "in_progress" }
  | { kind: "foreign" };

/** Validate an optional client-supplied attempt id. Absent is fine (legacy
 *  clients simply skip idempotent replay). Throws invalid-argument otherwise. */
export function validateAttemptId(attemptId: unknown): asserts attemptId is string | undefined {
  if (attemptId === undefined) return;
  if (
    typeof attemptId !== "string" ||
    attemptId.length === 0 ||
    attemptId.length > MAX_ATTEMPT_ID_LEN ||
    attemptId.includes("/")
  ) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "attemptId must be a short path-safe string when provided",
    );
  }
}

/** Pure decision over the current attempt doc. Exported for unit tests. */
export function decideAttempt(
  doc: AttemptDoc | undefined,
  uid: string,
  nowMs: number,
): AttemptDecision {
  if (doc === undefined) return { kind: "proceed" };
  if (doc.uid !== uid) return { kind: "foreign" };
  if (doc.status === "done") return { kind: "replay", result: doc.result };
  if (nowMs - doc.createdAtMs <= ATTEMPT_IN_PROGRESS_STALE_MS) {
    return { kind: "in_progress" };
  }
  return { kind: "proceed" }; // stale in_progress: presumed crashed, retake
}

/** Transactionally read the attempt doc and, when proceeding, mark it
 *  in_progress so concurrent duplicates observe the marker. */
export async function beginAttempt(
  db: Firestore,
  attemptId: string,
  uid: string,
  nowMs: number = Date.now(),
): Promise<AttemptDecision> {
  const ref = db.collection("attempts").doc(attemptId);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const doc = snap.exists ? (snap.data() as AttemptDoc) : undefined;
    const decision = decideAttempt(doc, uid, nowMs);
    if (decision.kind === "proceed") {
      tx.set(ref, {
        uid,
        status: "in_progress",
        createdAtMs: nowMs,
        // TTL guard for markers orphaned by a crash between fail and delete.
        expiresAt: admin.firestore.Timestamp.fromMillis(nowMs + ATTEMPT_TTL_MS),
      });
    }
    return decision;
  });
}

/** Store the handler's full response for verbatim replay, with a TTL stamp. */
export async function completeAttempt(
  db: Firestore,
  attemptId: string,
  uid: string,
  result: unknown,
  nowMs: number = Date.now(),
): Promise<void> {
  await db.collection("attempts").doc(attemptId).set({
    uid,
    status: "done",
    result,
    createdAtMs: nowMs,
    expiresAt: admin.firestore.Timestamp.fromMillis(nowMs + ATTEMPT_TTL_MS),
  });
}

/** Best-effort cleanup on handler failure so an immediate retry can proceed
 *  instead of waiting out the in_progress staleness window. */
export async function failAttempt(db: Firestore, attemptId: string): Promise<void> {
  try {
    await db.collection("attempts").doc(attemptId).delete();
  } catch (e) {
    console.error("failAttempt cleanup failed (non-fatal):", e);
  }
}

/** Convert a begin decision into the handler's control flow: returns the
 *  replayed result, throws for in_progress/foreign, or null to proceed. */
export function attemptDecisionToAction(decision: AttemptDecision): { replay: unknown } | null {
  if (decision.kind === "replay") return { replay: decision.result };
  if (decision.kind === "in_progress") {
    throw new functions.https.HttpsError(
      "aborted",
      "This claim is already being processed. Please wait a moment.",
    );
  }
  if (decision.kind === "foreign") {
    throw new functions.https.HttpsError(
      "permission-denied",
      "attemptId belongs to a different user",
    );
  }
  return null; // proceed
}
