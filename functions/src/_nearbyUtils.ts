import { getPoints } from "./_getPoints";
import { LookupResult } from "./types";

export interface SlimPostbox {
  monarch?: string;
  claimedToday: boolean;
}

export interface UserSpecificResult {
  slimPostboxes: Record<string, SlimPostbox>;
  updatedCounts: Record<string, number>;
  updatedPoints: { min: number; max: number };
  updatedCompass: Record<string, number>;
  claimedCompass: Record<string, number>;
}

/**
 * Pure function: applies per-user claim state to a raw LookupResult.
 *
 * - Strips precise location fields (geopoint, geohash) by building slim postbox records.
 * - Overrides `claimedToday` per postbox using the calling user's actual claims
 *   so other players' claims never block the current user.
 * - Recomputes cipher `_claimed` counts and `claimedToday` total for this user.
 * - Recomputes `points` range and `compass` directions using only unclaimed
 *   postboxes so the UI reflects what this user can still claim.
 */
export function applyUserClaims(
  full: LookupResult,
  userClaimedKeys: Set<string>
): UserSpecificResult {
  // Strip precise location fields; override claimedToday per-user.
  const slimPostboxes: Record<string, SlimPostbox> = {};
  for (const [id, pb] of Object.entries(full.postboxes)) {
    slimPostboxes[id] = {
      ...(pb.monarch !== undefined ? { monarch: pb.monarch } : {}),
      claimedToday: userClaimedKeys.has(id),
    };
  }

  // Carry over non-_claimed count keys (total, per-cipher totals) then
  // recompute the _claimed keys from the user's own claims.
  const updatedCounts: Record<string, number> = {};
  for (const [k, v] of Object.entries(full.counts)) {
    if (!k.endsWith("_claimed")) {
      updatedCounts[k] = v as number;
    }
  }
  let myClaimedCount = 0;
  for (const [id, pb] of Object.entries(full.postboxes)) {
    if (userClaimedKeys.has(id)) {
      myClaimedCount++;
      if (pb.monarch !== undefined) {
        const ck = `${pb.monarch}_claimed`;
        updatedCounts[ck] = (updatedCounts[ck] ?? 0) + 1;
      }
    }
  }
  updatedCounts.claimedToday = myClaimedCount;

  // Points range: unclaimed postboxes only.
  let unclaimedMin = Infinity;
  let unclaimedMax = 0;
  for (const [id, pb] of Object.entries(full.postboxes)) {
    if (!userClaimedKeys.has(id)) {
      const pts = pb.monarch !== undefined ? getPoints(pb.monarch) : 2;
      if (pts < unclaimedMin) unclaimedMin = pts;
      if (pts > unclaimedMax) unclaimedMax = pts;
    }
  }
  const updatedPoints = {
    min: isFinite(unclaimedMin) ? unclaimedMin : 0,
    max: unclaimedMax,
  };

  // Compass: split into unclaimed and claimed directions.
  const updatedCompass: Record<string, number> = {};
  const claimedCompass: Record<string, number> = {};
  for (const [id, pb] of Object.entries(full.postboxes)) {
    const dir = pb.compass?.exact;
    if (!dir) continue;
    if (userClaimedKeys.has(id)) {
      claimedCompass[dir] = (claimedCompass[dir] ?? 0) + 1;
    } else {
      updatedCompass[dir] = (updatedCompass[dir] ?? 0) + 1;
    }
  }

  return { slimPostboxes, updatedCounts, updatedPoints, updatedCompass, claimedCompass };
}
