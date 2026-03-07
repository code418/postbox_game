import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import { getPoints } from "./_getPoints";
import { lookupPostboxes } from "./_lookupPostboxes";

const database = admin.firestore();

interface StartScoringCallData {
  lat?: number;
  lng?: number;
  userid?: string;
}

interface StartScoringResult {
  found: boolean;
  claims: FirebaseFirestore.DocumentReference[];
}

export const startScoring = functions.https.onCall(async (data: StartScoringCallData, _context) => {
  const { lat, lng, userid } = data ?? {};
  if (lat === undefined || lat === null || lng === undefined || lng === null || userid === undefined || userid === null) {
    throw new functions.https.HttpsError("invalid-argument", "lat, lng, and userid are required");
  }

  const results = await lookupPostboxes(lat, lng, 20);
  const json: StartScoringResult = { found: results.counts.total > 0, claims: [] };

  if (json.found) {
    const claimPromises = Object.entries(results.postboxes).map(async ([key, postbox]) => {
      const claimData: Record<string, unknown> = {
        userid,
        timestamp: admin.firestore.Timestamp.now(),
        validated: false,
        postboxes: `/postboxes/${key}`,
      };
      if (postbox.monarch !== undefined) {
        claimData.monarch = postbox.monarch;
        claimData.points = getPoints(postbox.monarch);
      }
      return database.collection("claims").add(claimData);
    });
    json.claims = await Promise.all(claimPromises);
  }

  return json;
});
