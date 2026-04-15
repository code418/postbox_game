import "./adminInit";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import { getTodayLondon } from "./_dateUtils";
import { updateUserLeaderboards, mergeLifetimeEntries, LifetimeLeaderboardEntry } from "./_leaderboardUtils";

const database = admin.firestore();

const PENALTY_POINTS = 2;

interface QuizPenaltyCallData {
  correctCipher?: string;
  selectedCipher?: string;
}

export const quizPenalty = functions.https.onCall(async (request) => {
  const userid = request.auth?.uid;
  if (!userid) {
    throw new functions.https.HttpsError("unauthenticated", "Must be signed in");
  }

  const { correctCipher, selectedCipher } = (request.data as QuizPenaltyCallData) ?? {};
  if (!correctCipher || typeof correctCipher !== "string" || correctCipher.trim().length === 0) {
    throw new functions.https.HttpsError("invalid-argument", "correctCipher is required");
  }
  if (!selectedCipher || typeof selectedCipher !== "string" || selectedCipher.trim().length === 0) {
    throw new functions.https.HttpsError("invalid-argument", "selectedCipher is required");
  }

  const todayLondon = getTodayLondon();
  const now = admin.firestore.Timestamp.now();

  // Write the penalty document to the claims collection. The negative points
  // value is picked up automatically by the leaderboard aggregation queries.
  const penaltyRef = database.collection("claims").doc(`${userid}_penalty_${now.toMillis()}`);
  await penaltyRef.set({
    userid,
    timestamp: now,
    points: -PENALTY_POINTS,
    dailyDate: todayLondon,
    type: "quiz_penalty",
    correctCipher: correctCipher.trim(),
    selectedCipher: selectedCipher.trim(),
  });

  // Decrement lifetime points on the user doc. Negative totals are allowed.
  const userRef = database.collection("users").doc(userid);
  const userResult = await database.runTransaction(async (tx) => {
    const snap = await tx.get(userRef);
    const d = snap.data() ?? {};
    const currentLifetime = (d.lifetimePoints as number | undefined) ?? 0;
    const newLifetimePoints = currentLifetime - PENALTY_POINTS;
    tx.set(userRef, { lifetimePoints: newLifetimePoints }, { merge: true });
    return {
      displayName: (d.displayName as string | undefined),
      newLifetimePoints,
      uniquePostboxesClaimed: (d.uniquePostboxesClaimed as number | undefined) ?? 0,
    };
  });

  const displayName = userResult.displayName || `Player_${userid.slice(0, 6)}`;

  // Update period leaderboards (daily/weekly/monthly) and lifetime leaderboard
  // in parallel. Both are non-fatal — the penalty document is already written.
  await Promise.all([
    updateUserLeaderboards(userid, displayName, todayLondon, database).catch((err) => {
      console.error("period leaderboard update after penalty failed (non-fatal):", err);
    }),
    database.runTransaction(async (tx) => {
      const lifetimeRef = database.collection("leaderboards").doc("lifetime");
      const lifetimeSnap = await tx.get(lifetimeRef);
      const existingEntries = (lifetimeSnap.data()?.entries ?? []) as LifetimeLeaderboardEntry[];
      const updatedEntries = mergeLifetimeEntries(
        existingEntries, userid, displayName,
        userResult.uniquePostboxesClaimed, userResult.newLifetimePoints
      );
      tx.set(lifetimeRef, { periodKey: "lifetime", entries: updatedEntries }, { merge: false });
    }).catch((lifetimeErr) => {
      console.error("lifetime leaderboard update after penalty failed (non-fatal):", lifetimeErr);
    }),
  ]);

  return { penaltyApplied: true, pointsDeducted: PENALTY_POINTS };
});
