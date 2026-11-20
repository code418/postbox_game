// The "roughly where" map on the public postbox page: the outline of the box's
// county with the snapped ~1 km circle on it, as SVG path data the page drops
// into an inline <svg>. Drawn from the county GeoJSON already deployed with the
// functions (functions/data/uk_counties.geojson, read via util/county_lookup.js),
// so the page loads no map tiles from any third party (test/web_pages_test.dart
// forbids third-party loads; the privacy policy discloses none for maps).
//
// Never finer than a county outline: the only point drawn is the snapped
// circle from snappedArea(), never the box.

import { CountyMap, PublicArea } from "./_postboxPublic";

/** One county as county_lookup.js indexes it: GeoJSON polygons in [lng, lat]. */
export interface CountyPolygons {
  name: string;
  bbox: number[]; // [minLng, minLat, maxLng, maxLat]
  polys: number[][][][]; // [polygon][ring][point][lng, lat]
}

export interface CountyMapOptions {
  /** viewBox width in SVG units. */
  width: number;
  /** Margin round the outline, in SVG units. */
  pad: number;
  /** Douglas-Peucker tolerance, in SVG units. */
  tolerance: number;
  /** Rings whose projected bounding box is smaller than this in both
   *  directions (islets) are dropped. */
  minRingSize: number;
}

const DEFAULTS: CountyMapOptions = { width: 1000, pad: 24, tolerance: 1.2, minRingSize: 4 };

const METRES_PER_DEGREE_LAT = 111_320;

type Pt = [number, number];

function perpendicularDistance(p: Pt, a: Pt, b: Pt): number {
  const dx = b[0] - a[0];
  const dy = b[1] - a[1];
  const len2 = dx * dx + dy * dy;
  if (len2 === 0) return Math.hypot(p[0] - a[0], p[1] - a[1]);
  const t = Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2));
  return Math.hypot(p[0] - (a[0] + t * dx), p[1] - (a[1] + t * dy));
}

/** Iterative Douglas-Peucker on an open polyline (endpoints kept). */
export function simplifyLine(points: Pt[], tolerance: number): Pt[] {
  if (points.length <= 2) return points.slice();
  const keep = new Uint8Array(points.length);
  keep[0] = 1;
  keep[points.length - 1] = 1;
  const stack: Array<[number, number]> = [[0, points.length - 1]];
  while (stack.length) {
    const [start, end] = stack.pop()!;
    let maxDist = -1;
    let index = -1;
    for (let i = start + 1; i < end; i++) {
      const d = perpendicularDistance(points[i], points[start], points[end]);
      if (d > maxDist) {
        maxDist = d;
        index = i;
      }
    }
    if (index !== -1 && maxDist > tolerance) {
      keep[index] = 1;
      stack.push([start, index], [index, end]);
    }
  }
  return points.filter((_, i) => keep[i] === 1);
}

const fmt = (n: number): string => (Math.round(n * 10) / 10).toString();

/**
 * Projects [county] (equirectangular, scaled by cos of its mid-latitude so
 * shapes keep their proportions) into an SVG viewBox [opts.width] wide, and
 * draws [area] on it. Pure: the caller supplies the polygons.
 */
export function buildCountyMap(
  county: CountyPolygons,
  area: PublicArea,
  options: Partial<CountyMapOptions> = {},
): CountyMap {
  const opts = { ...DEFAULTS, ...options };
  const [minLng, minLat, maxLng, maxLat] = county.bbox;
  const kx = Math.cos((((minLat + maxLat) / 2) * Math.PI) / 180);
  const spanX = Math.max((maxLng - minLng) * kx, 1e-9);
  const spanY = Math.max(maxLat - minLat, 1e-9);
  const scale = (opts.width - 2 * opts.pad) / Math.max(spanX, spanY);
  const width = Math.round(spanX * scale + 2 * opts.pad);
  const height = Math.round(spanY * scale + 2 * opts.pad);
  const project = (lng: number, lat: number): Pt => [
    opts.pad + (lng - minLng) * kx * scale,
    opts.pad + (maxLat - lat) * scale,
  ];

  const parts: string[] = [];
  for (const polygon of county.polys) {
    for (const ring of polygon) {
      const projected = ring.map(([lng, lat]) => project(lng, lat));
      let rx0 = Infinity, ry0 = Infinity, rx1 = -Infinity, ry1 = -Infinity;
      for (const [x, y] of projected) {
        if (x < rx0) rx0 = x;
        if (x > rx1) rx1 = x;
        if (y < ry0) ry0 = y;
        if (y > ry1) ry1 = y;
      }
      if (rx1 - rx0 < opts.minRingSize && ry1 - ry0 < opts.minRingSize) continue;
      const simplified = simplifyLine(projected, opts.tolerance);
      if (simplified.length < 3) continue;
      parts.push(
        "M" + simplified.map(([x, y]) => `${fmt(x)} ${fmt(y)}`).join(" ") + "Z",
      );
    }
  }

  const [cx, cy] = project(area.lng, area.lat);
  const r = (area.radiusM / METRES_PER_DEGREE_LAT) * scale;
  return {
    width,
    height,
    outline: parts.join(""),
    circle: { cx: Number(fmt(cx)), cy: Number(fmt(cy)), r: Math.max(Number(fmt(r)), 0.1) },
  };
}

type CountyLoader = () => CountyPolygons[];

// Loaded lazily, as reports.ts does, so functions that never draw a map don't
// pay the ~900 kB GeoJSON parse on cold start.
let loader: CountyLoader = () =>
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  (require("../util/county_lookup") as { load: () => CountyPolygons[] }).load();

const outlines = new Map<string, CountyPolygons | null>();

/** Test hook: swap the county source and drop the cache. */
export function setCountyLoaderForTest(l: CountyLoader): void {
  loader = l;
  outlines.clear();
}

/**
 * The map for a box in the county stored as [countyName] (the full ONS name
 * from the importer, e.g. "Bristol, City of"). Null when the county is unknown
 * or the GeoJSON can't be read: the page then shows the county text only.
 */
export function countyMapFor(countyName: string | null, area: PublicArea | null): CountyMap | null {
  if (!countyName || !area) return null;
  let county = outlines.get(countyName);
  if (county === undefined) {
    try {
      county = loader().find((f) => f.name === countyName) ?? null;
    } catch (e) {
      console.warn("[countyMap] county outlines unavailable:", e);
      county = null;
    }
    outlines.set(countyName, county);
  }
  return county ? buildCountyMap(county, area) : null;
}
