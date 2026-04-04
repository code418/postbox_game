import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import { getPoints } from "./_getPoints";
import { lookupPostboxes } from "./_lookupPostboxes";

const database = admin.firestore();

interface StartScoringCallData {
  lat?: number;
  lng?: number;
}

interface StartScoringResult {
  found: boolean;
  claimed: number;
  points: number;
}

export const startScoring = functions.https.onCall(async (data: StartScoringCallData, context) => {
  const userid = context.auth?.uid;
  if (!userid) {
    throw new functions.https.HttpsError("unauthenticated", "Must be signed in to claim a postbox");
  }

  const { lat, lng } = data ?? {};
  if (lat === undefined || lat === null || lng === undefined || lng === null) {
    throw new functions.https.HttpsError("invalid-argument", "lat and lng are required");
  }

  const results = await lookupPostboxes(lat, lng, 20);
  const json: StartScoringResult = { found: results.counts.total > 0, claimed: 0, points: 0 };

  if (json.found) {
    const claimPromises = Object.entries(results.postboxes).map(async ([key, postbox]) => {
      const pts = postbox.monarch !== undefined ? getPoints(postbox.monarch) : 2;
      const claimData: Record<string, unknown> = {
        userid,
        timestamp: admin.firestore.Timestamp.now(),
        validated: false,
        postboxes: `/postbox/${key}`,
        points: pts,
      };
      if (postbox.monarch !== undefined) {
        claimData.monarch = postbox.monarch;
      }
      await database.collection("claims").add(claimData);
      return pts;
    });
    const earnedPoints = await Promise.all(claimPromises);
    json.claimed = earnedPoints.length;
    json.points = earnedPoints.reduce((sum, p) => sum + p, 0);
  }

  return json;
});
