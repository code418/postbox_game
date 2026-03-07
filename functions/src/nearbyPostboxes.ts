import * as functions from "firebase-functions";
import { lookupPostboxes } from "./_lookupPostboxes";

interface NearbyCallData {
  lat?: number;
  lng?: number;
  meters?: number;
}

export const nearbyPostboxes = functions.https.onCall(async (data: NearbyCallData, _context) => {
  const { lat, lng, meters } = data ?? {};
  if (lat === undefined || lat === null || lng === undefined || lng === null || meters === undefined || meters === null) {
    throw new functions.https.HttpsError("invalid-argument", "lat, lng, and meters are required");
  }
  return lookupPostboxes(lat, lng, meters);
});
