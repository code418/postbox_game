/**
 * _geo.ts — pure geo helpers shared by lookupPostboxes, routePostboxes, reports,
 * and the plan_route CLI script. No firebase-admin / adminInit imports so the
 * CLI can require this without triggering the default-credentials init.
 */

import type { PostboxDoc } from "./types";

// Maximum geohash precision used by setPrecision (smallest cell). MUST match
// the precision postboxes are STORED at — the prefix-query pattern relies on
// stored geohashes being at least as precise as the query prefix. Drift here
// silently returns zero docs for queries at the stored-but-now-deeper level.
//
// Hardcoded mirror in two places:
//   - functions/import_postboxes.js:  GEOHASH_PRECISION = 9
//   - functions/src/reports.ts:       geohash.encode(lat, lng, 9)
// Pinned by a setPrecision test (functions/src/test/test.index.ts).
export const MAX_GEOHASH_PRECISION = 9;

// Thresholds are the SHORTER of the geohash cell's lat/lng dimensions (the
// height at even precisions, which are rectangular).  When the radius fits
// inside one cell's shorter dimension, a 1-ring (center + 8 neighbors)
// guaranteed covers a disc of that radius around any point in the center
// cell — including users near the edge.  Previously the even-precision
// thresholds used cell width (the longer dimension), which left a coverage
// hole in the lat direction: a 30 m claim radius at precision 8 (38 m × 19 m)
// could miss postboxes ~20–30 m due N/S of a user sitting near the top or
// bottom edge of their center cell.
export function setPrecision(km: number): number {
  if (km <= 0.00477) return MAX_GEOHASH_PRECISION;    // 4.77 m × 4.77 m
  if (km <= 0.0191) return 8;     // 38.2 m × 19.1 m
  if (km <= 0.153) return 7;      // 153 m × 153 m
  if (km <= 0.61) return 6;       // 1.22 km × 0.61 km
  if (km <= 4.89) return 5;       // 4.89 km × 4.89 km
  if (km <= 19.5) return 4;       // 39.1 km × 19.5 km
  if (km <= 156) return 3;        // 156 km × 156 km
  if (km <= 625) return 2;        // 1250 km × 625 km
  return 1;
}

export function getLatLng(geopoint: PostboxDoc["geopoint"]): { lat: number; lng: number } | null {
  if (!geopoint) return null;
  const lat = geopoint._latitude ?? geopoint.latitude;
  const lng = geopoint._longitude ?? geopoint.longitude;
  if (lat === undefined || lat === null || lng === undefined || lng === null) return null;
  return { lat, lng };
}
