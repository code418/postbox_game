import * as functions from "firebase-functions";
import { lookupPostboxes } from "./_lookupPostboxes";

interface NearbyCallData {
  lat?: number;
  lng?: number;
  meters?: number;
}

export const nearbyPostboxes = functions.https.onCall(async (request) => {
  if (!request.auth?.uid) {
    throw new functions.https.HttpsError("unauthenticated", "Must be signed in to scan for postboxes");
  }
  const data = request.data as NearbyCallData;
  const { lat, lng, meters } = data ?? {};
  if (lat === undefined || lat === null || lng === undefined || lng === null || meters === undefined || meters === null) {
    throw new functions.https.HttpsError("invalid-argument", "lat, lng, and meters are required");
  }
  if (!Number.isFinite(lat) || lat < -90 || lat > 90) {
    throw new functions.https.HttpsError("invalid-argument", "lat must be a finite number between -90 and 90");
  }
  if (!Number.isFinite(lng) || lng < -180 || lng > 180) {
    throw new functions.https.HttpsError("invalid-argument", "lng must be a finite number between -180 and 180");
  }
  if (!Number.isFinite(meters) || meters <= 0) {
    throw new functions.https.HttpsError("invalid-argument", "meters must be a positive number");
  }
  // Cap radius at 2km to prevent runaway Firestore queries.
  const clampedMeters = Math.min(meters, 2000);
  const full = await lookupPostboxes(lat, lng, clampedMeters);

  // Strip precise location fields (geopoint, geohash, dailyClaim) before
  // sending to the client. The client only needs monarch (for the quiz) and
  // claimedToday (for UI state); all other fields are internal.
  const slimPostboxes: Record<string, { monarch?: string; claimedToday: boolean }> = {};
  for (const [id, pb] of Object.entries(full.postboxes)) {
    slimPostboxes[id] = {
      ...(pb.monarch !== undefined ? { monarch: pb.monarch } : {}),
      claimedToday: pb.claimedToday ?? false,
    };
  }

  return { ...full, postboxes: slimPostboxes };
});
