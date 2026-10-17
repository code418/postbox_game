// Google Street View for the local review dashboard: "what does the street
// look like at this reported spot?". Finds the nearest outdoor panorama and
// aims the camera at the spot, so the box (or the gap where one should be)
// is in the middle of the frame.
//
// Two Google products, both free of charge:
//  - Street View Static API *metadata* requests ("is there a panorama near
//    here, where and when was it taken?") cost nothing and use no quota;
//  - the Maps Embed API's streetview mode is free and unlimited.
// Both need a Google Maps Platform API key. Without one the dashboard still
// offers a keyless Google Maps link (documented Maps URLs), just not aimed.
// No firebase-admin imports.

import * as geolib from "geolib";
import type { StreetViewDto } from "./_reviewTypes";

export const STREETVIEW_METADATA_ENDPOINT = "https://maps.googleapis.com/maps/api/streetview/metadata";
export const STREETVIEW_EMBED_ENDPOINT = "https://www.google.com/maps/embed/v1/streetview";
/** A panorama further than this from the spot is unlikely to show the box. */
export const STREETVIEW_SEARCH_RADIUS_M = 50;
export const STREETVIEW_CACHE_TTL_MS = 6 * 60 * 60 * 1000;
export const STREETVIEW_REQUEST_TIMEOUT_MS = 10_000;
/** Slightly down and zoomed in: a pillar box 5-20 m away sits mid-frame. */
export const STREETVIEW_PITCH = -5;
export const STREETVIEW_FOV = 70;

export interface LatLng {
  lat: number;
  lng: number;
}

export type StreetViewMetadata =
  | { status: "ok"; panoId: string; lat: number; lng: number; date: string | null; copyright: string | null }
  | { status: "none" };

export class StreetViewError extends Error {}

const coord = (p: LatLng) => `${p.lat.toFixed(6)},${p.lng.toFixed(6)}`;

/** Metadata lookup for the nearest outdoor panorama (user-uploaded indoor
 *  photospheres excluded) within radiusM of the spot. */
export function buildStreetViewMetadataUrl(spot: LatLng, key: string, radiusM: number = STREETVIEW_SEARCH_RADIUS_M): string {
  const q = new URLSearchParams({ location: coord(spot), radius: String(radiusM), source: "outdoor", key });
  return `${STREETVIEW_METADATA_ENDPOINT}?${q}`;
}

/** Parses a metadata answer. "No imagery here" is a result; a refused key,
 *  quota or malformed answer is a StreetViewError. */
export function parseStreetViewMetadata(body: unknown): StreetViewMetadata {
  const b = (body ?? {}) as Record<string, unknown>;
  const status = typeof b.status === "string" ? b.status : "";
  if (status === "ZERO_RESULTS" || status === "NOT_FOUND") return { status: "none" };
  if (status !== "OK") {
    const detail = typeof b.error_message === "string" && b.error_message.trim() !== "" ? ` ${b.error_message.trim()}` : "";
    if (status === "REQUEST_DENIED") {
      throw new StreetViewError(`Google refused the Street View lookup. Check that GOOGLE_MAPS_API_KEY is valid and allowed to use the Street View Static API.${detail}`);
    }
    if (status === "OVER_QUERY_LIMIT") throw new StreetViewError(`Google says the Maps key is over its quota.${detail}`);
    throw new StreetViewError(`Street View lookup failed (${status || "no status"}).${detail}`);
  }
  const loc = b.location as Record<string, unknown> | undefined;
  if (typeof b.pano_id !== "string" || b.pano_id === "" || typeof loc?.lat !== "number" || typeof loc?.lng !== "number") {
    throw new StreetViewError("Street View answered without a panorama position.");
  }
  return {
    status: "ok",
    panoId: b.pano_id,
    lat: loc.lat,
    lng: loc.lng,
    date: typeof b.date === "string" && /^\d{4}-\d{2}$/.test(b.date) ? b.date : null,
    copyright: typeof b.copyright === "string" ? b.copyright : null,
  };
}

/** Compass bearing from one point to another, whole degrees in 0..359. */
export function bearingDegrees(from: LatLng, to: LatLng): number {
  const deg = geolib.getGreatCircleBearing({ latitude: from.lat, longitude: from.lng }, { latitude: to.lat, longitude: to.lng });
  return Math.round(deg) % 360;
}

/** Maps Embed API streetview URL for one panorama, camera on headingDeg. */
export function buildStreetViewEmbedUrl(key: string, panoId: string, headingDeg: number): string {
  const q = new URLSearchParams({
    key,
    pano: panoId,
    heading: String(headingDeg),
    pitch: String(STREETVIEW_PITCH),
    fov: String(STREETVIEW_FOV),
  });
  return `${STREETVIEW_EMBED_ENDPOINT}?${q}`;
}

/** Keyless Google Maps link (Maps URLs, map_action=pano). With a known
 *  panorama it opens that one aimed at the spot; otherwise Google picks the
 *  nearest panorama to the spot and its own heading. */
export function googleMapsStreetViewUrl(spot: LatLng, pano?: { panoId: string; lat: number; lng: number; headingDeg: number }): string {
  const q = new URLSearchParams({ api: "1", map_action: "pano", viewpoint: coord(pano ?? spot) });
  if (pano) {
    q.set("pano", pano.panoId);
    q.set("heading", String(pano.headingDeg));
    q.set("pitch", String(STREETVIEW_PITCH));
    q.set("fov", String(STREETVIEW_FOV));
  }
  return `https://www.google.com/maps/@?${q}`;
}

/** The dashboard's answer for a spot: no key, no imagery, or a panorama
 *  aimed at the spot. */
export function describeStreetView(spot: LatLng, key: string | null, meta: StreetViewMetadata | null): StreetViewDto {
  if (key === null || meta === null) return { status: "not_configured", mapsUrl: googleMapsStreetViewUrl(spot) };
  if (meta.status === "none") return { status: "none", radiusM: STREETVIEW_SEARCH_RADIUS_M, mapsUrl: googleMapsStreetViewUrl(spot) };
  const headingDeg = bearingDegrees(meta, spot);
  return {
    status: "ok",
    panoId: meta.panoId,
    lat: meta.lat,
    lng: meta.lng,
    distanceM: geolib.getDistance({ latitude: meta.lat, longitude: meta.lng }, { latitude: spot.lat, longitude: spot.lng }),
    headingDeg,
    date: meta.date,
    copyright: meta.copyright,
    embedUrl: buildStreetViewEmbedUrl(key, meta.panoId, headingDeg),
    mapsUrl: googleMapsStreetViewUrl(spot, { panoId: meta.panoId, lat: meta.lat, lng: meta.lng, headingDeg }),
  };
}

type GetFetch = (url: string, init: { headers: Record<string, string>; signal?: AbortSignal }) => Promise<{
  ok: boolean;
  status: number;
  json(): Promise<unknown>;
}>;

/** Metadata lookups with a TTL cache keyed by the spot. */
export class StreetViewClient {
  private readonly cache = new Map<string, { meta: StreetViewMetadata; at: number }>();

  constructor(
    private readonly key: string,
    private readonly fetchImpl: GetFetch = fetch as unknown as GetFetch,
    private readonly now: () => number = Date.now,
    private readonly ttlMs: number = STREETVIEW_CACHE_TTL_MS,
    private readonly requestTimeoutMs: number = STREETVIEW_REQUEST_TIMEOUT_MS,
  ) {}

  async lookup(spot: LatLng): Promise<StreetViewMetadata> {
    const cacheKey = coord(spot);
    const hit = this.cache.get(cacheKey);
    if (hit && this.now() - hit.at < this.ttlMs) return hit.meta;
    let res;
    try {
      res = await this.fetchImpl(buildStreetViewMetadataUrl(spot, this.key), {
        headers: { Accept: "application/json" },
        signal: AbortSignal.timeout(this.requestTimeoutMs),
      });
    } catch (e) {
      if ((e as Error).name === "TimeoutError" || (e as Error).name === "AbortError") {
        throw new StreetViewError(`Google Street View didn't answer within ${Math.round(this.requestTimeoutMs / 1000)} s.`);
      }
      throw new StreetViewError(`Google Street View unreachable: ${(e as Error).message}`);
    }
    if (!res.ok) throw new StreetViewError(`Google Street View returned HTTP ${res.status}.`);
    const meta = parseStreetViewMetadata(await res.json());
    this.cache.set(cacheKey, { meta, at: this.now() });
    return meta;
  }
}
