import * as functions from "firebase-functions";
import { lookupPostboxes } from "./_lookupPostboxes";

interface NearbyCallData {
  lat?: number;
  lng?: number;
  meters?: number;
}

export const nearbyPostboxes = functions.https.onCall(async (request) => {
  if (!request.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Must be signed in to find nearby postboxes.");
  }
  const data = request.data as NearbyCallData;
  const { lat, lng, meters } = data ?? {};
  if (lat === undefined || lat === null || lng === undefined || lng === null || meters === undefined || meters === null) {
    throw new functions.https.HttpsError("invalid-argument", "lat, lng, and meters are required");
  }
  return lookupPostboxes(lat, lng, meters);
});
