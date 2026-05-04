'use strict';

/**
 * county_lookup.js — point-in-polygon resolver mapping (lat, lng) to a UK
 * county / unitary authority name, sourced from the ONS "Counties and Unitary
 * Authorities (December 2023) Boundaries UK BUC" GeoJSON shipped under
 * functions/data/uk_counties.geojson.
 *
 * The lookup is purely synchronous after load(). Polygons are indexed by
 * bounding box so the ray-casting cost per point is paid only on the small
 * subset of features whose bbox contains the point — typically 1–3 candidates.
 *
 * No external dependency: a ~30-line ring ray-casting routine handles
 * Polygon and MultiPolygon geometries (the only types in the ONS dataset).
 *
 * Usage:
 *   const counties = require('./util/county_lookup');
 *   counties.load();
 *   counties.countyForPoint(50.2660, -5.0527); // → 'Cornwall'
 *   counties.slug('City of Edinburgh');        // → 'city-of-edinburgh'
 */

const fs = require('fs');
const path = require('path');

const DEFAULT_GEOJSON = path.join(__dirname, '..', 'data', 'uk_counties.geojson');

let _features = null; // Array<{ name, slug, bbox: [minX, minY, maxX, maxY], polys: number[][][][] }>

function slug(name) {
  if (!name) return null;
  return String(name)
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '') || null;
}

function _bbox(coords) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  const visit = (c) => {
    if (typeof c[0] === 'number') {
      if (c[0] < minX) minX = c[0];
      if (c[0] > maxX) maxX = c[0];
      if (c[1] < minY) minY = c[1];
      if (c[1] > maxY) maxY = c[1];
    } else for (const inner of c) visit(inner);
  };
  visit(coords);
  return [minX, minY, maxX, maxY];
}

/** Ray-casting on a single linear ring [[x,y], …]. Even-odd rule. */
function _pointInRing(x, y, ring) {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const xi = ring[i][0], yi = ring[i][1];
    const xj = ring[j][0], yj = ring[j][1];
    const intersect = ((yi > y) !== (yj > y)) &&
      (x < ((xj - xi) * (y - yi)) / (yj - yi || Number.EPSILON) + xi);
    if (intersect) inside = !inside;
  }
  return inside;
}

/** Polygon = [outerRing, ...holes]. Inside outer && not inside any hole. */
function _pointInPolygon(x, y, polygon) {
  if (!polygon.length || !_pointInRing(x, y, polygon[0])) return false;
  for (let i = 1; i < polygon.length; i++) {
    if (_pointInRing(x, y, polygon[i])) return false;
  }
  return true;
}

/** Loads and indexes the county GeoJSON. Idempotent. */
function load(geojsonPath = DEFAULT_GEOJSON) {
  if (_features) return _features;
  if (!fs.existsSync(geojsonPath)) {
    throw new Error(`County GeoJSON not found at ${geojsonPath}. ` +
      `Download from ONS Open Geography Portal: services1.arcgis.com → ` +
      `Counties_and_Unitary_Authorities_December_2023_Boundaries_UK_BUC ` +
      `(GeoJSON, EPSG:4326).`);
  }
  const raw = JSON.parse(fs.readFileSync(geojsonPath, 'utf8'));
  _features = [];
  for (const f of (raw.features ?? [])) {
    // Accept either ONS field name or the simplified asset's `name` field.
    const name = f.properties?.CTYUA23NM ?? f.properties?.name;
    if (!name) continue;
    const g = f.geometry;
    if (!g) continue;
    const polys = g.type === 'Polygon' ? [g.coordinates]
                : g.type === 'MultiPolygon' ? g.coordinates
                : null;
    if (!polys) continue;
    _features.push({
      name,
      slug: slug(name),
      bbox: _bbox(g.coordinates),
      polys,
    });
  }
  return _features;
}

/** Returns the county name for a (lat, lng) point, or null if no match. */
function countyForPoint(lat, lng) {
  if (!_features) load();
  if (typeof lat !== 'number' || typeof lng !== 'number'
      || !Number.isFinite(lat) || !Number.isFinite(lng)) return null;
  const x = lng, y = lat; // GeoJSON is [lng, lat]
  for (const f of _features) {
    const [minX, minY, maxX, maxY] = f.bbox;
    if (x < minX || x > maxX || y < minY || y > maxY) continue;
    for (const polygon of f.polys) {
      if (_pointInPolygon(x, y, polygon)) return f.name;
    }
  }
  return null;
}

module.exports = {
  load,
  slug,
  countyForPoint,
  // Exposed for tests.
  _pointInRing,
  _pointInPolygon,
};
