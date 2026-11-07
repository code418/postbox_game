// Raw "every postbox doc near here" geohash query, shared by the plan_route
// CLI and the local review dashboard's duplicate detection.
//
// Unlike lookupPostboxes (the claim path), this does NOT hide soft-pruned
// (`removedFromOsm`) boxes and attaches no per-user claim state: callers want
// to see everything that is stored. It imports firebase-admin for types only
// and never touches adminInit, so a script can load it before choosing how to
// initialise the Admin SDK.

import type { firestore } from "firebase-admin";
import * as geohash from "ngeohash";
import { getLatLng, setPrecision } from "./_geo";
import { metresBetween } from "./_routePlanner";
import type { PostboxDoc } from "./types";

export interface NearbyPostbox {
  id: string;
  data: PostboxDoc;
  lat: number;
  lng: number;
  /** Metres from the query point. */
  distanceM: number;
}

/**
 * Postbox docs around (lat, lng), from the 9 geohash cells covering
 * `radiusM`, de-duplicated, in discovery order. Docs with no usable geopoint
 * are dropped. With `filterToRadius: false` the coarse 9-cell set is returned
 * unfiltered (plan_route trims it with its own geometry).
 */
/** A postbox found by [queryPostboxesInCells]. */
export interface CellPostbox {
  id: string;
  lat: number;
  lng: number;
  monarch?: string;
}

/**
 * Every CLAIMABLE postbox stored under any of [cells] (geohash prefixes), for
 * the workout-claim route matcher. Unlike queryPostboxesNear this DOES skip
 * soft-pruned (`removedFromOsm`) boxes — the claim path's lookupPostboxes
 * skips them too, so offering one would end in a `found:false` claim. Prefix
 * range queries run [concurrency] at a time; results are de-duplicated.
 */
export async function queryPostboxesInCells(
  db: firestore.Firestore,
  cells: string[],
  concurrency = 25,
): Promise<CellPostbox[]> {
  const seen = new Set<string>();
  const out: CellPostbox[] = [];
  // Sequential chunks bound the number of in-flight queries per route.
  for (let i = 0; i < cells.length; i += concurrency) {
    const chunk = cells.slice(i, i + concurrency);
    // eslint-disable-next-line no-await-in-loop
    const snaps = await Promise.all(
      chunk.map((prefix) => db.collection("postbox").orderBy("geohash").startAt(prefix).endAt(prefix + "").get())
    );
    for (const snap of snaps) {
      for (const doc of snap.docs) {
        if (seen.has(doc.id)) continue;
        seen.add(doc.id);
        const data = doc.data() as PostboxDoc;
        if (data.removedFromOsm === true) continue;
        const pos = getLatLng(data.geopoint);
        if (!pos) continue;
        out.push({ id: doc.id, lat: pos.lat, lng: pos.lng, ...(data.monarch !== undefined ? { monarch: data.monarch } : {}) });
      }
    }
  }
  return out;
}

export async function queryPostboxesNear(
  db: firestore.Firestore,
  lat: number,
  lng: number,
  radiusM: number,
  opts: { filterToRadius?: boolean } = {}
): Promise<NearbyPostbox[]> {
  const filterToRadius = opts.filterToRadius ?? true;
  const precision = setPrecision(radiusM / 1000);
  const centreHash = geohash.encode(lat, lng, precision);
  const cells = [centreHash, ...geohash.neighbors(centreHash)];

  const snapshots = await Promise.all(
    cells.map((prefix) => db.collection("postbox").orderBy("geohash").startAt(prefix).endAt(prefix + "").get())
  );

  const seen = new Set<string>();
  const out: NearbyPostbox[] = [];
  for (const snap of snapshots) {
    for (const doc of snap.docs) {
      if (seen.has(doc.id)) continue;
      seen.add(doc.id);
      const data = doc.data() as PostboxDoc;
      const pos = getLatLng(data.geopoint);
      if (!pos) continue;
      const distanceM = metresBetween({ lat, lng }, pos);
      if (filterToRadius && distanceM > radiusM) continue;
      out.push({ id: doc.id, data, lat: pos.lat, lng: pos.lng, distanceM });
    }
  }
  return out;
}
