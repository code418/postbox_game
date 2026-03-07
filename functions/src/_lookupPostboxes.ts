import * as admin from "firebase-admin";
import * as geohash from "ngeohash";
import * as geolib from "geolib";
import { getPoints } from "./_getPoints";
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

function getLatLng(geopoint: PostboxDoc["position"]): { lat: number; lng: number } | null {
  if (!geopoint?.geopoint) return null;
  const g = geopoint.geopoint as { _latitude?: number; _longitude?: number; latitude?: number; longitude?: number };
  const lat = g._latitude ?? g.latitude;
  const lng = g._longitude ?? g.longitude;
  if (lat === undefined || lat === null || lng === undefined || lng === null) return null;
  return { lat, lng };
}

export async function lookupPostboxes(lat: number, lng: number, meters: number): Promise<LookupResult> {
  const result: LookupResult = {
    postboxes: {},
    counts: { total: 0 },
    points: { max: 0, min: 0 },
    compass: {},
  };

  if (!meters || !lat || !lng) return result;

  const radius = meters / 1000;
  const precision = setPrecision(radius);
  const centerHash = geohash.encode(lat, lng, precision);
  const neighborHashes = geohash.neighbors(centerHash);
  const areas = [centerHash, ...neighborHashes];

  const postboxRef = database.collection("postboxes");
  const queries = areas.map((geohashPrefix) => {
    const end = geohashPrefix + "\uf8ff";
    return postboxRef
      .orderBy("position.geohash")
      .startAt(geohashPrefix)
      .endAt(end)
      .get();
  });

  const snapshots = await Promise.all(queries);
  const from = { latitude: lat, longitude: lng };

  for (const snapshot of snapshots) {
    for (const doc of snapshot.docs) {
      const data = doc.data() as PostboxDoc;
      const pos = getLatLng(data.position);
      if (!pos) continue;

      const distance = geolib.getDistance(from, { latitude: pos.lat, longitude: pos.lng });
      if (distance > meters) continue;

      result.counts.total++;
      if (data.monarch !== undefined) {
        const pts = getPoints(data.monarch);
        result.points.max += pts;
        result.points.min += pts;
        result.counts[data.monarch] = (result.counts[data.monarch] ?? 0) + 1;
      } else {
        result.points.max += 12;
        result.points.min += 2;
      }

      const docWithMeta: PostboxDoc = { ...data, distance };
      docWithMeta.compass = geolib.getCompassDirection(from, { latitude: pos.lat, longitude: pos.lng }) as { exact?: string };
      const compassPos = docWithMeta.compass?.exact;
      if (compassPos) {
        result.compass[compassPos] = (result.compass[compassPos] ?? 0) + 1;
      }
      result.postboxes[doc.id] = docWithMeta;
    }
  }

  return result;
}
