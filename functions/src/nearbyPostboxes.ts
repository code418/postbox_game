import "./adminInit";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import { getTodayLondon } from "./_dateUtils";
import { applyUserClaims } from "./_nearbyUtils";
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
    userClaimsSnap.docs
      .map(d => d.data().postboxes as string | undefined)
      .filter((ref): ref is string => typeof ref === "string")
      .map(ref => ref.replace("/postbox/", ""))
  );

  const { slimPostboxes, updatedCounts, updatedPoints, updatedCompass } =
    applyUserClaims(full, userClaimedKeys);

  // Return only the 4 intended fields — explicit rather than ...full spread
  // so future LookupResult fields (e.g. precise geopoints) are not accidentally
  // leaked to clients before they're deliberately included here.
  return {
    postboxes: slimPostboxes,
    counts: updatedCounts,
    points: updatedPoints,
    compass: updatedCompass,
  };
});
