import "./adminInit";
import { monitorAppCheck } from "./_appCheck";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { FIRESTORE_TRIGGER_REGION } from "./_region";
import {
  evaluateClaimSignals,
  applyTrustDecay,
  DEFAULT_TRUST_SCORE,
} from "./_abuseSignals";

// SHADOW MODE: the detector only records flags + decays an internal trust score.
// It NEVER blocks, voids, or otherwise affects a claim. Enforcement (step-up
// verification, voiding) is a deferred follow-up gated behind this flag.
const SHADOW_MODE = true;

/** Cap on the recent same-device claims read to count distinct accounts. A
 *  heuristic bound for the shadow-mode repeated-device signal — enough to
 *  surface multi-accounting without an unbounded scan. */
const REPEATED_DEVICE_SCAN_LIMIT = 100;

const database = admin.firestore();

/**
 * onClaimCreated — shadow-mode claim anomaly detector.
 *
 * 2nd-gen Firestore trigger in europe-west4 (eur3's Eventarc region; eur3 has no
 * Gen1 Firestore triggers — see FIRESTORE_TRIGGER_REGION). Runs out-of-band so
 * it adds zero latency/risk to the claim path. Reads the inputs startScoring
 * persisted on the claim (travelSpeed, clientTsMs, coordKey6) plus one count
 * query, evaluates the pure signals, and on any breach writes a
 * `moderationFlags/{id}` doc and decays `trustScores/{uid}`.
 *
 * Deliberately never throws: a detector fault must not affect anything.
 */
export const onClaimCreated = onDocumentCreated(
  { document: "claims/{claimId}", region: FIRESTORE_TRIGGER_REGION },
  async (event) => {
    try {
      const snap = event.data;
      if (!snap) return;
      const claim = snap.data();
      const claimId = event.params.claimId;
      const uid = claim.userid as string | undefined;
      if (!uid) return;

      const serverTsMs =
        (claim.timestamp as admin.firestore.Timestamp | undefined)?.toMillis?.() ?? Date.now();
      const clientTsMs = typeof claim.clientTsMs === "number" ? (claim.clientTsMs as number) : undefined;
      const travelSpeed = typeof claim.travelSpeed === "number" ? (claim.travelSpeed as number) : undefined;
      const coordKey6 = typeof claim.coordKey6 === "string" ? (claim.coordKey6 as string) : undefined;
      const deviceIdHash = typeof claim.deviceIdHash === "string" ? (claim.deviceIdHash as string) : undefined;

      // Coordinate clustering: how many of this user's claims sit at the same
      // rounded coordinate (this one included). Two equality filters are served
      // by single-field indexes (zigzag merge) — no composite index needed.
      let repeatCount = 0;
      if (coordKey6) {
        const agg = await database
          .collection("claims")
          .where("userid", "==", uid)
          .where("coordKey6", "==", coordKey6)
          .count()
          .get();
        repeatCount = agg.data().count;
      }

      // Repeated-device: distinct accounts that have claimed from this claim's
      // device hash in the last 24h. Bounded read (equality + timestamp range —
      // needs the composite index claims(deviceIdHash, timestamp)).
      let distinctDeviceAccounts = 0;
      if (deviceIdHash) {
        const cutoff = admin.firestore.Timestamp.fromMillis(Date.now() - 24 * 60 * 60 * 1000);
        const recent = await database
          .collection("claims")
          .where("deviceIdHash", "==", deviceIdHash)
          .where("timestamp", ">=", cutoff)
          .orderBy("timestamp", "desc")
          .limit(REPEATED_DEVICE_SCAN_LIMIT)
          .get();
        const uids = new Set<string>();
        for (const d of recent.docs) {
          const u = d.data().userid;
          if (typeof u === "string") uids.add(u);
        }
        distinctDeviceAccounts = uids.size;
      }

      const { reasons, severity, signals } = evaluateClaimSignals({
        travelSpeedMPerMin: travelSpeed,
        serverTsMs,
        clientTsMs,
        coordRepeatCount: repeatCount,
        distinctDeviceAccounts,
      });
      if (reasons.length === 0) return; // nothing anomalous

      // Internal visibility via Cloud Logging — values only, never exact coords.
      console.warn(
        `[abuse:shadow] uid=${uid} claim=${claimId} reasons=${reasons.join(",")} severity=${severity} ` +
          `speedMPerMin=${signals.travelSpeedMPerMin.toFixed(1)} clockSkewMs=${signals.clockSkewMs} ` +
          `coordRepeat=${signals.coordRepeatCount} deviceAccounts=${signals.deviceAccountCount}`,
      );

      // Surface the claim coordinate on the (admin-only) flag doc so the review
      // screen can show a map link — admins can't read other users' claim docs
      // directly (claims are owner-read-only).
      const flagLat = typeof claim.userLat === "number" ? (claim.userLat as number) : undefined;
      const flagLng = typeof claim.userLng === "number" ? (claim.userLng as number) : undefined;

      await database.collection("moderationFlags").add({
        uid,
        claimId,
        reasons,
        severity,
        shadow: SHADOW_MODE,
        signals,
        ...(flagLat !== undefined ? { lat: flagLat } : {}),
        ...(flagLng !== undefined ? { lng: flagLng } : {}),
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        reviewed: false,
      });

      // Decay the server-only trust score. Best-effort: a failure here must not
      // surface anywhere, so it's caught by the outer try/catch.
      const trustRef = database.collection("trustScores").doc(uid);
      await database.runTransaction(async (tx) => {
        const tSnap = await tx.get(trustRef);
        const current = (tSnap.data()?.score as number | undefined) ?? DEFAULT_TRUST_SCORE;
        tx.set(
          trustRef,
          { score: applyTrustDecay(current, severity), updatedAt: admin.firestore.FieldValue.serverTimestamp() },
          { merge: true },
        );
      });
    } catch (e) {
      console.error("onClaimCreated detector failed (non-fatal):", e);
    }
  },
);

interface ReviewFlagData {
  flagId?: unknown;
  action?: unknown;
  reviewNote?: unknown;
}

/**
 * reviewFlag — admin marks a moderation flag as reviewed.
 *
 * Admin-gated exactly like reviewReport. Shadow phase only stamps the flag; it
 * does NOT void claims (that's a deferred enforcement follow-up reusing
 * recomputeUserAggregates in _recomputeScores.ts).
 */
export const reviewFlag = functions.https.onCall(async (request) => {
  monitorAppCheck(request, "reviewFlag");
  if (request.auth?.token?.admin !== true) {
    throw new functions.https.HttpsError("permission-denied", "Admin access required");
  }
  const adminUid = request.auth.uid;
  const data = (request.data as ReviewFlagData) ?? {};

  const flagId = data.flagId;
  if (typeof flagId !== "string" || flagId.length === 0 || flagId.includes("/")) {
    throw new functions.https.HttpsError("invalid-argument", "flagId is required");
  }
  const action = typeof data.action === "string" ? data.action.slice(0, 200) : undefined;
  const reviewNote = typeof data.reviewNote === "string" ? data.reviewNote.slice(0, 500) : undefined;

  const ref = database.collection("moderationFlags").doc(flagId);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new functions.https.HttpsError("not-found", "Flag not found");
  }

  const update: Record<string, unknown> = {
    reviewed: true,
    reviewedBy: adminUid,
    reviewedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
  if (action !== undefined) update.action = action;
  if (reviewNote !== undefined) update.reviewNote = reviewNote;
  await ref.set(update, { merge: true });

  return { ok: true };
});
