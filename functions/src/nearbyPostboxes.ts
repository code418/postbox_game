import "./adminInit";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import { getTodayLondon } from "./_dateUtils";
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
  const uid = request.auth!.uid;
  const todayLondon = getTodayLondon();

  // Run postbox lookup and today's user-claims query in parallel.
  const [full, userClaimsSnap] = await Promise.all([
    lookupPostboxes(lat, lng, clampedMeters),
    admin.firestore().collection("claims")
      .where("userid", "==", uid)
      .where("dailyDate", "==", todayLondon)
      .get(),
  ]);

  // Build the set of postbox IDs already claimed by THIS user today.
  // The postboxes field is stored as "/postbox/{key}".
  const userClaimedKeys = new Set(
    userClaimsSnap.docs.map(d => {
      const ref = d.data().postboxes as string;
      return ref.replace("/postbox/", "");
    })
  );

  // Strip precise location fields (geopoint, geohash, dailyClaim) before
  // sending to the client.  Override claimedToday with per-user status so
  // the Claim and Nearby screens only show boxes as "claimed" when the
  // current user has claimed them — other players' claims never block.
  const slimPostboxes: Record<string, { monarch?: string; claimedToday: boolean }> = {};
  for (const [id, pb] of Object.entries(full.postboxes)) {
    slimPostboxes[id] = {
      ...(pb.monarch !== undefined ? { monarch: pb.monarch } : {}),
      claimedToday: userClaimedKeys.has(id),
    };
  }

  // Override counts.claimedToday with the per-user count so the client's
  // "X of N available" and "All claimed today" logic is also per-user.
  const myClaimedCount = Object.keys(full.postboxes)
    .filter(k => userClaimedKeys.has(k)).length;

  return {
    ...full,
    postboxes: slimPostboxes,
    counts: { ...full.counts, claimedToday: myClaimedCount },
  };
});
