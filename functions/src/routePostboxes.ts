import "./adminInit";
import { monitorAppCheck } from "./_appCheck";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import * as geohash from "ngeohash";
import { getTodayLondon } from "./_dateUtils";
import { setPrecision, getLatLng } from "./_lookupPostboxes";
import { getGameConfig, resolvePointsForMonarch } from "./_config";
import type { PostboxDoc } from "./types";
import {
  metresBetween,
  midpoint,
  filterToCorridor,
  filterToEllipse,
  beamSearchOrienteering,
  type Candidate,
  type Point,
} from "./_routePlanner";

const MAX_DIRECT_DISTANCE_M = 30_000;
const BEAM_WIDTH = 50;
const DEFAULT_SPEED_KMH = 4.5;
const DEFAULT_PER_CLAIM_SECONDS = 60;

interface RouteCallData {
  startLat?: number;
  startLng?: number;
  destLat?: number;
  destLng?: number;
  mode?: string;
  corridorMetres?: number;
  detourMinutes?: number;
  speedKmh?: number;
  perClaimSeconds?: number;
}

export const routePostboxes = functions.https.onCall(async (request) => {
  monitorAppCheck(request, "routePostboxes");
  if (!request.auth?.uid) {
    throw new functions.https.HttpsError("unauthenticated", "Must be signed in to plan a route");
  }
  const uid = request.auth.uid;
  const data = (request.data ?? {}) as RouteCallData;

  // ── Validate lat/lng inputs ───────────────────────────────────────────────
  const { startLat, startLng, destLat, destLng } = data;
  if (startLat === undefined || startLat === null ||
      startLng === undefined || startLng === null ||
      destLat === undefined || destLat === null ||
      destLng === undefined || destLng === null) {
    throw new functions.https.HttpsError("invalid-argument", "startLat, startLng, destLat, and destLng are required");
  }
  if (!Number.isFinite(startLat) || startLat < -90 || startLat > 90) {
    throw new functions.https.HttpsError("invalid-argument", "startLat must be a finite number between -90 and 90");
  }
  if (!Number.isFinite(startLng) || startLng < -180 || startLng > 180) {
    throw new functions.https.HttpsError("invalid-argument", "startLng must be a finite number between -180 and 180");
  }
  if (!Number.isFinite(destLat) || destLat < -90 || destLat > 90) {
    throw new functions.https.HttpsError("invalid-argument", "destLat must be a finite number between -90 and 90");
  }
  if (!Number.isFinite(destLng) || destLng < -180 || destLng > 180) {
    throw new functions.https.HttpsError("invalid-argument", "destLng must be a finite number between -180 and 180");
  }

  // ── Validate mode ─────────────────────────────────────────────────────────
  const { mode } = data;
  if (mode !== "corridor" && mode !== "detour") {
    throw new functions.https.HttpsError("invalid-argument", 'mode must be "corridor" or "detour"');
  }

  // ── Validate mode-specific params ─────────────────────────────────────────
  let corridorMetres = 0;
  if (mode === "corridor") {
    if (data.corridorMetres === undefined || data.corridorMetres === null) {
      throw new functions.https.HttpsError("invalid-argument", "corridorMetres is required for corridor mode");
    }
    if (!Number.isFinite(data.corridorMetres) || data.corridorMetres < 50 || data.corridorMetres > 500) {
      throw new functions.https.HttpsError("invalid-argument", "corridorMetres must be a finite number between 50 and 500");
    }
    corridorMetres = data.corridorMetres;
  }

  let detourMinutes = 0;
  if (mode === "detour") {
    if (data.detourMinutes === undefined || data.detourMinutes === null) {
      throw new functions.https.HttpsError("invalid-argument", "detourMinutes is required for detour mode");
    }
    if (!Number.isFinite(data.detourMinutes) || data.detourMinutes < 0 || data.detourMinutes > 120) {
      throw new functions.https.HttpsError("invalid-argument", "detourMinutes must be a finite number between 0 and 120");
    }
    detourMinutes = data.detourMinutes;
  }

  // ── Optional params ───────────────────────────────────────────────────────
  let speedKmh = DEFAULT_SPEED_KMH;
  if (data.speedKmh !== undefined && data.speedKmh !== null) {
    if (!Number.isFinite(data.speedKmh) || data.speedKmh < 2 || data.speedKmh > 14) {
      throw new functions.https.HttpsError("invalid-argument", "speedKmh must be a finite number between 2 and 14");
    }
    speedKmh = data.speedKmh;
  }

  let perClaimSeconds = DEFAULT_PER_CLAIM_SECONDS;
  if (data.perClaimSeconds !== undefined && data.perClaimSeconds !== null) {
    if (!Number.isFinite(data.perClaimSeconds) || data.perClaimSeconds < 0 || data.perClaimSeconds > 300) {
      throw new functions.https.HttpsError("invalid-argument", "perClaimSeconds must be a finite number between 0 and 300");
    }
    perClaimSeconds = data.perClaimSeconds;
  }

  // ── Distance cap ──────────────────────────────────────────────────────────
  const start: Point = { lat: startLat, lng: startLng };
  const dest: Point = { lat: destLat, lng: destLng };
  const directDistanceM = metresBetween(start, dest);
  if (directDistanceM > MAX_DIRECT_DISTANCE_M) {
    throw new functions.https.HttpsError("invalid-argument", `Direct distance (${Math.round(directDistanceM)} m) exceeds the 30 km limit`);
  }

  // ── Budget computations ───────────────────────────────────────────────────
  const speedMps = speedKmh * 1000 / 3600;
  const budgetSeconds = mode === "corridor"
    ? directDistanceM / speedMps
    : directDistanceM / speedMps + detourMinutes * 60;
  const budgetDistanceM = speedMps * budgetSeconds;

  // ── Bounding-circle radius and centre for Firestore query ─────────────────
  const queryRadiusM = mode === "corridor"
    ? directDistanceM / 2 + corridorMetres + 50
    : budgetDistanceM / 2;
  const centre = midpoint(start, dest);

  // ── Fetch candidate postboxes (inline geohash prefix query) ───────────────
  const radiusKm = queryRadiusM / 1000;
  const precision = setPrecision(radiusKm);
  const centreHash = geohash.encode(centre.lat, centre.lng, precision);
  const neighborHashes = geohash.neighbors(centreHash);
  const areas = [centreHash, ...neighborHashes];

  const db = admin.firestore();
  const postboxRef = db.collection("postbox");
  const queries = areas.map((prefix) => {
    const end = prefix + "\uf8ff";
    return postboxRef.orderBy("geohash").startAt(prefix).endAt(end).get();
  });

  const [snapshots, userClaimsSnap, gameConfig] = await Promise.all([
    Promise.all(queries),
    db.collection("claims")
      .where("userid", "==", uid)
      .where("dailyDate", "==", getTodayLondon())
      .get(),
    // Remote-Config points so the "worth Y points" headline matches what
    // startScoring would award (both via resolvePointsForMonarch).
    getGameConfig(),
  ]);

  // Build claimed-today set
  const userClaimedKeys = new Set(
    userClaimsSnap.docs
      .map(d => d.data().postboxes as string | undefined)
      .filter((ref): ref is string => typeof ref === "string")
      .map(ref => ref.replace(/^\/postbox\//, ""))
  );

  // Dedupe and map to Candidates
  const seen = new Set<string>();
  const candidates: Candidate[] = [];

  for (const snapshot of snapshots) {
    for (const doc of snapshot.docs) {
      if (seen.has(doc.id)) continue;
      seen.add(doc.id);

      const data2 = doc.data() as PostboxDoc;
      // Match _lookupPostboxes: don't surface postboxes the OSM data says
      // have been removed. Without this, route planning would route the user
      // past phantom postboxes that startScoring would refuse to claim.
      if (data2.removedFromOsm === true) continue;
      const pos = getLatLng(data2.geopoint);
      if (!pos) continue;

      // Skip already-claimed-today
      if (userClaimedKeys.has(doc.id)) continue;

      candidates.push({
        id: doc.id,
        lat: pos.lat,
        lng: pos.lng,
        monarch: data2.monarch ?? null,
        points: resolvePointsForMonarch(gameConfig, data2.monarch),
        reference: data2.reference,
        county: data2.county,
      });
    }
  }

  // ── Mode-specific filter and scoring ─────────────────────────────────────
  const warnings: string[] = [];
  let count: number;
  let points: number;

  if (mode === "corridor") {
    const filtered = filterToCorridor(candidates, start, dest, corridorMetres);
    count = filtered.length;
    points = filtered.reduce((s, c) => s + c.points, 0);
    if (count === 0) warnings.push("no unclaimed postboxes en-route");
  } else {
    const filtered = filterToEllipse(candidates, start, dest, budgetDistanceM);
    const result = beamSearchOrienteering(
      start, dest, filtered, budgetSeconds, speedMps, perClaimSeconds, BEAM_WIDTH
    );
    count = result.visited.size;
    points = result.score;
    if (count === 0) warnings.push("no unclaimed postboxes en-route");
  }

  // ── Response (never includes per-postbox ids, coords, or details) ─────────
  return {
    count,
    points,
    directDistanceM,
    budgetDistanceM,
    warnings,
  };
});
