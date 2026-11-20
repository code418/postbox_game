// Pure helpers for per-postbox links (https://the-postbox-game.web.app/postbox/{CODE}).
//
// A link names a postbox by an opaque, random link code, never by its doc id:
// an `osm_<n>` id is an OpenStreetMap node number, and openstreetmap.org/node/<n>
// shows the box's exact position. A player sharing a claim on their home
// postbox would otherwise be sharing roughly where they live. Codes are minted
// lazily (only for boxes someone shares) in postboxLinks.ts.
//
// Everything here is free of firebase-admin so it can be unit-tested directly.
// Several facts are duplicated in other languages and pinned by
// test/cross_language_sync_test.dart: the link-code pattern (lib/deep_links.dart,
// web/postbox.html), MONARCH_LABELS and CYPHER_PHRASES (lib/monarch_info.dart,
// lib/widgets/share_card.dart) and the county display-name regex
// (lib/unpacked/unpacked_stats.dart).

import { randomBytes } from "crypto";
import * as geohash from "ngeohash";

/** Crockford base32 (no I, L, O or U): 32 symbols, so a random byte masked to
 *  5 bits maps onto it uniformly. The same alphabet as invite codes. */
export const POSTBOX_LINK_CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/** 10 symbols = 50 bits. Deliberately not 8, the invite-code length, so the
 *  two kinds of code can never be mistaken for each other. */
export const POSTBOX_LINK_CODE_LENGTH = 10;

/** Pinned literal: keep identical in lib/deep_links.dart and web/postbox.html. */
export const POSTBOX_LINK_CODE_RE = /^[0-9A-HJKMNP-TV-Z]{10}$/;

/** A postbox doc id this module will mint a link for: an imported OSM node
 *  (`osm_<digits>`) or a box added from an accepted report
 *  (`manual_<Firestore auto-id>`). Server-side input validation only. */
export const POSTBOX_DOC_ID_RE = /^(?:osm_[1-9][0-9]{0,14}|manual_[A-Za-z0-9]{1,40})$/;

export const POSTBOX_LINK_HOST = "the-postbox-game.web.app";

/**
 * Canonicalise a link code from a URL or typed input: trim, uppercase, drop
 * spaces and hyphens, and apply Crockford's decoding aliases (I and L read as
 * 1, O as 0). Returns null unless the result is exactly a valid code.
 */
export function normalisePostboxLinkCode(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const code = raw
    .trim()
    .toUpperCase()
    .replace(/[\s-]/g, "")
    .replace(/[IL]/g, "1")
    .replace(/O/g, "0");
  return POSTBOX_LINK_CODE_RE.test(code) ? code : null;
}

/** A fresh random link code. [randomBytesFn] is injectable for tests. */
export function generatePostboxLinkCode(
  randomBytesFn: (n: number) => Uint8Array = randomBytes,
): string {
  const bytes = randomBytesFn(POSTBOX_LINK_CODE_LENGTH);
  let code = "";
  for (let i = 0; i < POSTBOX_LINK_CODE_LENGTH; i++) {
    code += POSTBOX_LINK_CODE_ALPHABET[bytes[i] & 31];
  }
  return code;
}

/** The public URL for a link code. */
export function postboxLinkUrl(code: string): string {
  return `https://${POSTBOX_LINK_HOST}/postbox/${code}`;
}

/**
 * The link code from a request path of the form `/api/postbox/{CODE}` (an
 * optional trailing slash allowed). Null for anything else: extra segments,
 * bad percent-encoding, or a malformed code.
 */
export function parsePostboxApiPath(path: string): string | null {
  const m = /^\/api\/postbox\/([^/]+)\/?$/.exec(path);
  if (!m) return null;
  let segment: string;
  try {
    segment = decodeURIComponent(m[1]);
  } catch {
    return null;
  }
  return normalisePostboxLinkCode(segment);
}

/** Pinned against MonarchInfo.labels in lib/monarch_info.dart. */
export const MONARCH_LABELS: Readonly<Record<string, string>> = {
  PLAIN: "Plain / no cypher",
  EIIR: "Elizabeth II (1952–2022)",
  CIIIR: "Charles III (2022–)",
  GVIR: "George VI (1936–1952)",
  GVR: "George V (1910–1936)",
  EVIIIR: "Edward VIII (1936)",
  EVIIR: "Edward VII (1901–1910)",
  VR: "Victoria (1837–1901)",
  GR: "George (generic)",
  SCOTTISH_CROWN: "Scottish Crown (Scotland only)",
};

/** Pinned against cypherPhrase() in lib/widgets/share_card.dart. The
 *  fallback for a plain or unknown cypher is "a". */
export const CYPHER_PHRASES: Readonly<Record<string, string>> = {
  VR: "a Victorian",
  EVIIR: "an Edward VII",
  EVIIIR: "an Edward VIII",
  GR: "a George V",
  GVR: "a George V",
  GVIR: "a George VI",
  EIIR: "an Elizabeth II",
  CIIIR: "a King Charles III",
  SCOTTISH_CROWN: "a Scottish Crown",
};

/** Display label for a stored monarch code; null (no cypher recorded) reads
 *  as the plain label, and an unknown code is shown as itself. */
export function monarchLabel(monarch: string | null | undefined): string {
  if (!monarch) return MONARCH_LABELS.PLAIN;
  return MONARCH_LABELS[monarch] ?? monarch;
}

/** "a Victorian" for "a Victorian postbox"; "a" for a plain or unknown box. */
export function cypherPhrase(monarch: string | null | undefined): string {
  return (monarch && CYPHER_PHRASES[monarch]) || "a";
}

/** Drops the ONS ", City of" / ", County of" tail ("Bristol, City of" →
 *  "Bristol"). Same regex as countyDisplayName in
 *  lib/unpacked/unpacked_stats.dart. */
export const COUNTY_SUFFIX_RE = /,\s*(City|County) of\s*$/;

export function countyDisplayName(name: string): string {
  return name.replace(COUNTY_SUFFIX_RE, "");
}

/** Radius of the public "roughly here" circle. The circle is centred on the
 *  centre of the box's geohash-6 cell (about 0.75 x 0.61 km at UK latitudes),
 *  so the box is at most ~505 m from the centre even at 49°N and always lies
 *  inside the circle. Pinned by a test at the cell corners. */
export const PUBLIC_AREA_RADIUS_M = 600;

const PUBLIC_AREA_GEOHASH_PRECISION = 6;

export interface PublicArea {
  lat: number;
  lng: number;
  radiusM: number;
}

/**
 * The rough area shown for a box at ([lat], [lng]): the centre of its
 * geohash-6 cell, never the box's own position. Every box in a cell gets the
 * same centre, so repeated requests can't narrow it down.
 */
export function snappedArea(lat: number, lng: number): PublicArea {
  const cell = geohash.encode(lat, lng, PUBLIC_AREA_GEOHASH_PRECISION);
  const centre = geohash.decode(cell);
  return {
    lat: Math.round(centre.latitude * 1e5) / 1e5,
    lng: Math.round(centre.longitude * 1e5) / 1e5,
    radiusM: PUBLIC_AREA_RADIUS_M,
  };
}

/** How near a signed-in player is to a linked box. Never a direction and
 *  never an exact distance: the fuzzy compass rule applies to links too. */
export type PostboxProximity =
  | "claimable"
  | "claimedToday"
  | "veryClose"
  | "shortWalk"
  | "underKm"
  | "far"
  | "unknown";

/** Distance band for [distanceM] metres, given the live claim radius. */
export function proximityBand(
  distanceM: number,
  claimRadiusM: number,
): Exclude<PostboxProximity, "claimedToday" | "unknown"> {
  if (distanceM <= claimRadiusM) return "claimable";
  if (distanceM < 100) return "veryClose";
  if (distanceM < 300) return "shortWalk";
  if (distanceM < 1000) return "underKm";
  return "far";
}

/** The fields of a postbox doc this module reads. */
export interface PostboxDocFields {
  monarch?: unknown;
  county?: unknown;
  removedFromOsm?: unknown;
  geopoint?: { latitude?: unknown; longitude?: unknown } | null;
}

/** The county map drawn on the public page (see _countyMap.ts). */
export interface CountyMap {
  width: number;
  height: number;
  /** SVG path data for the county outline, in viewBox units. */
  outline: string;
  circle: { cx: number; cy: number; r: number };
}

/** What anyone may learn about a linked postbox. */
export interface PostboxPublicInfo {
  monarch: string | null;
  label: string;
  phrase: string;
  points: number;
  county: string | null;
  claims: { total: number };
  map: CountyMap | null;
}

/** The box's position, when the doc carries a valid geopoint. */
export function postboxPosition(
  doc: PostboxDocFields,
): { lat: number; lng: number } | null {
  const lat = doc.geopoint?.latitude;
  const lng = doc.geopoint?.longitude;
  if (typeof lat !== "number" || typeof lng !== "number") return null;
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null;
  return { lat, lng };
}

/** False for a missing doc or one pruned from OpenStreetMap. */
export function isLivePostbox(doc: PostboxDocFields | undefined | null): doc is PostboxDocFields {
  return doc !== null && doc !== undefined && doc.removedFromOsm !== true;
}

/**
 * Builds the public view of a postbox from an ALLOWLIST of fields. Never
 * spread the doc: it carries the exact geopoint, the geohash, the OSM id and
 * the reference, any of which pinpoints the box.
 */
export function buildPostboxPublicInfo(
  doc: PostboxDocFields,
  claimsTotal: number,
  points: number,
  map: CountyMap | null,
): PostboxPublicInfo {
  const monarch = typeof doc.monarch === "string" && doc.monarch ? doc.monarch : null;
  const county = typeof doc.county === "string" && doc.county
    ? countyDisplayName(doc.county)
    : null;
  return {
    monarch,
    label: monarchLabel(monarch),
    phrase: cypherPhrase(monarch),
    points,
    county,
    claims: { total: claimsTotal },
    map,
  };
}

/** Cache-Control for each public API status. Successes are cached at the CDN
 *  for an hour (claim counts lag by at most that); a malformed code never
 *  changes, so it is cached longest. */
export function cacheControlFor(status: number): string {
  switch (status) {
    case 200: return "public, max-age=300, s-maxage=3600";
    case 404: return "public, max-age=60, s-maxage=300";
    case 400: return "public, max-age=3600, s-maxage=86400";
    default: return "no-store";
  }
}
