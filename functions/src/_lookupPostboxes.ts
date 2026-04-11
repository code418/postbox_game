import * as admin from "firebase-admin";
import * as geohash from "ngeohash";
import * as geolib from "geolib";
import { getPoints } from "./_getPoints";
import { getTodayLondon } from "./_dateUtils";
import type { LookupResult, PostboxDoc } from "./types";

const database = admin.firestore();

function setPrecision(km: number): number {
  if (km <= 0.00477) return 9;
  if (km <= 0.0382) return 8;
  if (km <= 0.153) return 7;
  if (km <= 1.22) return 6;
  if (km <= 4.89) return 5;
  if (km <= 39.1) return 4;
  if (km <= 156) return 3;
  if (km <= 1250) return 2;
  return 1;
}

function getLatLng(geopoint: PostboxDoc["geopoint"]): { lat: number; lng: number } | null {
  if (!geopoint) return null;
  const lat = geopoint._latitude ?? geopoint.latitude;
  const lng = geopoint._longitude ?? geopoint.longitude;
  if (lat === undefined || lat === null || lng === undefined || lng === null) return null;
  return { lat, lng };
}

export async function lookupPostboxes(lat: number, lng: number, meters: number): Promise<LookupResult> {
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
  const todayLondon = getTodayLondon();
  const seen = new Set<string>();

  for (const snapshot of snapshots) {
    for (const doc of snapshot.docs) {
      if (seen.has(doc.id)) continue;
      seen.add(doc.id);
      const data = doc.data() as PostboxDoc;
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
