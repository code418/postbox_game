import "./adminInit";
import * as admin from "firebase-admin";
import * as geohash from "ngeohash";
import * as geolib from "geolib";
import { getPoints } from "./_getPoints";
import { getTodayLondon } from "./_dateUtils";
import type { LookupResult, PostboxDoc } from "./types";

// Re-exported from _geo.ts so existing call sites continue to import these from
// _lookupPostboxes; the canonical definitions live in _geo.ts so the CLI script
// (functions/src/scripts/plan_route.ts) can import them without triggering the
// adminInit side-effect at the top of this file.
import { MAX_GEOHASH_PRECISION, setPrecision, getLatLng } from "./_geo";
export { MAX_GEOHASH_PRECISION, setPrecision, getLatLng };

const database = admin.firestore();

/**
 * Look up postboxes within [meters] of ([lat], [lng]).
 *
 * [today] is the London day used for the `claimedToday` comparisons; it
 * defaults to the real today (live scans). The offline flush path passes the
 * claim's CAPTURE day so a backdated claim is adjudicated against the right
 * day's dailyClaim markers (ROADMAP v1.5, offline play Phase 2).
 */
export async function lookupPostboxes(lat: number, lng: number, meters: number, today?: string): Promise<LookupResult> {
  const result: LookupResult = {
    postboxes: {},
    counts: { total: 0, claimedToday: 0 },
    points: { max: 0, min: 0 },
    compass: {},
  };
  // Track min/max across individual unclaimed postboxes (not accumulated total).
  let unclaimedMin = Infinity;
  let unclaimedMax = 0;

  if (meters === null || meters === undefined || lat === null || lat === undefined || lng === null || lng === undefined) return result;

  const radius = meters / 1000;
  const precision = setPrecision(radius);
  const centerHash = geohash.encode(lat, lng, precision);
  const neighborHashes = geohash.neighbors(centerHash);
  const areas = [centerHash, ...neighborHashes];

  const postboxRef = database.collection("postbox");
  const queries = areas.map((geohashPrefix) => {
    const end = geohashPrefix + "\uf8ff";
    return postboxRef
      .orderBy("geohash")
      .startAt(geohashPrefix)
      .endAt(end)
      .get();
  });

  const snapshots = await Promise.all(queries);
  const from = { latitude: lat, longitude: lng };
  const todayLondon = today ?? getTodayLondon();
  const seen = new Set<string>();

  for (const snapshot of snapshots) {
    for (const doc of snapshot.docs) {
      if (seen.has(doc.id)) continue;
      seen.add(doc.id);
      const data = doc.data() as PostboxDoc;
      // Skip postboxes soft-pruned by import_postboxes.js --prune. These
      // documents are kept around so a future re-import can clear the flag,
      // but they shouldn't be presented as claimable: the OSM data already
      // says they're gone.
      if (data.removedFromOsm === true) continue;
      const pos = getLatLng(data.geopoint);
      if (!pos) continue;

      const distance = geolib.getDistance(from, { latitude: pos.lat, longitude: pos.lng });
      if (distance > meters) continue;

      result.counts.total++;
      if (data.monarch !== undefined) {
        result.counts[data.monarch] = (result.counts[data.monarch] ?? 0) + 1;
      }

      const compassDir = geolib.getCompassDirection(from, { latitude: pos.lat, longitude: pos.lng });
      if (compassDir) {
        // result.compass accumulates ALL postboxes (claimed + unclaimed by any
        // user). Callers should override this with per-user data via
        // applyUserClaims, which recomputes compass for unclaimed postboxes only.
        result.compass[compassDir] = (result.compass[compassDir] ?? 0) + 1;
      }

      const isClaimedToday = data.dailyClaim?.date === todayLondon;
      if (isClaimedToday) {
        result.counts.claimedToday++;
        // Per-cipher claimed count (e.g. EIIR_claimed) lets the client show
        // "2 of 3 available" in the monarch breakdown without a second query.
        if (data.monarch !== undefined) {
          const claimedKey = `${data.monarch}_claimed`;
          result.counts[claimedKey] = (result.counts[claimedKey] ?? 0) + 1;
        }
      } else {
        // Track the per-postbox point value for min/max range display.
        const pts = data.monarch !== undefined ? getPoints(data.monarch) : 2;
        if (pts < unclaimedMin) unclaimedMin = pts;
        if (pts > unclaimedMax) unclaimedMax = pts;
      }

      result.postboxes[doc.id] = { ...data, distance, compass: { exact: compassDir }, claimedToday: isClaimedToday };
    }
  }

  // Resolve the per-postbox min/max (stays 0/0 when all postboxes are already claimed today).
  result.points.min = isFinite(unclaimedMin) ? unclaimedMin : 0;
  result.points.max = unclaimedMax;
  return result;
}
