import "./adminInit";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import { getTodayLondon } from "./_dateUtils";
import { getWeekStart, getMonthStart } from "./_leaderboardUtils";

export type HistoryPeriod = "daily" | "weekly" | "monthly" | "lifetime";

interface UserClaimHistoryCallData {
  period?: string;
}

interface RawClaim {
  userid?: string;
  postboxes?: string;
  dailyDate?: string;
  points?: number;
  monarch?: string;
}

export interface ClaimHistoryEntry {
  postboxId: string;
  lat: number;
  lng: number;
  monarch?: string;
  reference?: string;
  timesClaimed: number;
  firstClaimed: string;
  lastClaimed: string;
  totalPoints: number;
}

interface PostboxLocation {
  lat: number;
  lng: number;
  monarch?: string;
  reference?: string;
}

interface NormalisedClaim {
  postboxId: string;
  dailyDate: string;
  points: number;
  monarch?: string;
}

// Firestore admin SDK allows up to 500 documents per getAll call, but batching
// smaller keeps memory bounded and latency predictable.
const POSTBOX_BATCH_SIZE = 100;

/**
 * Pure reducer: groups claim records by postbox id, joining in the postbox
 * location lookup to produce map-ready entries. Claims whose postbox is missing
 * from the lookup (e.g. the postbox doc was deleted after import) are skipped.
 * Exported for unit testing.
 */
export function aggregateClaimHistory(
  claims: NormalisedClaim[],
  postboxes: Record<string, PostboxLocation | undefined>
): ClaimHistoryEntry[] {
  const byId = new Map<string, ClaimHistoryEntry>();
  for (const c of claims) {
    const pb = postboxes[c.postboxId];
    if (!pb) continue;
    const existing = byId.get(c.postboxId);
    if (existing) {
      existing.timesClaimed += 1;
      existing.totalPoints += c.points;
      if (c.dailyDate < existing.firstClaimed) existing.firstClaimed = c.dailyDate;
      if (c.dailyDate > existing.lastClaimed) existing.lastClaimed = c.dailyDate;
    } else {
      byId.set(c.postboxId, {
        postboxId: c.postboxId,
        lat: pb.lat,
        lng: pb.lng,
        monarch: pb.monarch ?? c.monarch,
        reference: pb.reference,
        timesClaimed: 1,
        firstClaimed: c.dailyDate,
        lastClaimed: c.dailyDate,
        totalPoints: c.points,
      });
    }
  }
  // Most-recently-claimed first. Ties broken by postbox id for deterministic order.
  return Array.from(byId.values()).sort((a, b) => {
    if (a.lastClaimed !== b.lastClaimed) return a.lastClaimed < b.lastClaimed ? 1 : -1;
    return a.postboxId < b.postboxId ? -1 : 1;
  });
}

/**
 * Returns the inclusive lower bound dailyDate (YYYY-MM-DD, London time) for a
 * given history period, or null for lifetime.
 */
export function periodStartDate(period: HistoryPeriod, today: string): string | null {
  if (period === "daily") return today;
  if (period === "weekly") return getWeekStart(today);
  if (period === "monthly") return getMonthStart(today);
  return null;
}

export const userClaimHistory = functions.https.onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new functions.https.HttpsError(
      "unauthenticated",
      "Must be signed in to view claim history"
    );
  }

  const { period } = (request.data as UserClaimHistoryCallData) ?? {};
  if (
    period !== "daily" &&
    period !== "weekly" &&
    period !== "monthly" &&
    period !== "lifetime"
  ) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "period must be one of: daily, weekly, monthly, lifetime"
    );
  }

  const db = admin.firestore();
  const today = getTodayLondon();

  // dailyDate is already used for leaderboard range queries — reuse it rather
  // than the timestamp field so we share Firestore's composite index.
  let query: admin.firestore.Query = db.collection("claims").where("userid", "==", uid);
  const start = periodStartDate(period, today);
  if (period === "daily") {
    query = query.where("dailyDate", "==", today);
  } else if (start !== null) {
    query = query.where("dailyDate", ">=", start).where("dailyDate", "<=", today);
  }

  const claimsSnap = await query.get();

  const normalised: NormalisedClaim[] = [];
  for (const doc of claimsSnap.docs) {
    const data = doc.data() as RawClaim;
    const path = data.postboxes;
    const dailyDate = data.dailyDate;
    if (typeof path !== "string" || typeof dailyDate !== "string") continue;
    normalised.push({
      postboxId: path.replace(/^\/postbox\//, ""),
      dailyDate,
      points: typeof data.points === "number" ? data.points : 0,
      monarch: data.monarch,
    });
  }

  if (normalised.length === 0) {
    return { entries: [], period };
  }

  const uniqueIds = Array.from(new Set(normalised.map((c) => c.postboxId)));
  const postboxMap: Record<string, PostboxLocation> = {};

  for (let i = 0; i < uniqueIds.length; i += POSTBOX_BATCH_SIZE) {
    const batch = uniqueIds.slice(i, i + POSTBOX_BATCH_SIZE);
    const refs = batch.map((id) => db.collection("postbox").doc(id));
    const docs = await db.getAll(...refs);
    for (const doc of docs) {
      if (!doc.exists) continue;
      const data = doc.data() as {
        geopoint?: admin.firestore.GeoPoint;
        monarch?: string;
        reference?: string;
      };
      const geo = data.geopoint;
      if (!geo || typeof geo.latitude !== "number" || typeof geo.longitude !== "number") continue;
      postboxMap[doc.id] = {
        lat: geo.latitude,
        lng: geo.longitude,
        monarch: data.monarch,
        reference: data.reference,
      };
    }
  }

  const entries = aggregateClaimHistory(normalised, postboxMap);
  return { entries, period };
});
