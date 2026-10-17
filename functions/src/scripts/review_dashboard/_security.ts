// Request gating for the local review dashboard. The server holds production
// admin power (it writes postbox, claims, leaderboards and reports through the
// Admin SDK), so a page on any other website must not be able to drive it:
//
//  - it binds to 127.0.0.1 only;
//  - Host must be our own loopback host:port (defeats DNS rebinding, where an
//    attacker's hostname is re-pointed at 127.0.0.1);
//  - every /api request carries a per-launch random token in a custom header.
//    A cross-origin page can't add that header without a CORS preflight, and
//    the server answers no preflight (no CORS headers at all), so neither
//    reads nor writes can be forged;
//  - POSTs must also come from our own Origin with a JSON body.
//
// Pure functions only, so they're unit-tested in test.index.ts.

import { timingSafeEqual } from "crypto";
import * as path from "path";

export const TOKEN_HEADER = "x-review-token";
export const MAX_BODY_BYTES = 64 * 1024;
export const MIN_TOKEN_LENGTH = 32;

/** Loopback origins the API accepts POSTs from: the server itself, plus the
 *  Vite dev server when running with --dev. */
export function allowedOrigins(port: number, devPort: number | null): string[] {
  const hosts = ["127.0.0.1", "localhost"];
  const ports = devPort === null ? [port] : [port, devPort];
  return ports.flatMap((p) => hosts.map((h) => `http://${h}:${p}`));
}

/** Host header check (DNS-rebinding defence). */
export function isAllowedHost(host: string | undefined, port: number): boolean {
  return host === `127.0.0.1:${port}` || host === `localhost:${port}`;
}

export function isAllowedOrigin(origin: string | undefined, allowed: ReadonlyArray<string>): boolean {
  return typeof origin === "string" && allowed.includes(origin);
}

/** Sec-Fetch-Site for an /api request: absent (curl, older clients) or
 *  same-origin. "same-site" is refused too: another localhost port is a
 *  different app. */
export function isAllowedFetchSite(value: string | undefined): boolean {
  return value === undefined || value === "same-origin";
}

/** Constant-time token comparison. */
export function tokenMatches(provided: string | undefined, expected: string): boolean {
  if (typeof provided !== "string") return false;
  const a = Buffer.from(provided);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

export function isJsonContentType(value: string | undefined): boolean {
  return typeof value === "string" && /^application\/json(\s*;|$)/i.test(value.trim());
}

/**
 * Maps a URL path to a file under `root`, or null if it escapes the root or is
 * malformed. "/" and extension-less paths (client-side routes) map to the SPA
 * entry point.
 */
export function resolveStaticPath(root: string, urlPath: string): string | null {
  let decoded: string;
  try {
    decoded = decodeURIComponent(urlPath.split("?")[0].split("#")[0]);
  } catch {
    return null;
  }
  if (decoded.includes("\0")) return null;
  const rel = decoded === "/" || path.extname(decoded) === "" ? "index.html" : decoded.replace(/^\/+/, "");
  const full = path.resolve(root, rel);
  const rootResolved = path.resolve(root);
  if (full !== rootResolved && !full.startsWith(rootResolved + path.sep)) return null;
  return full;
}

const CONTENT_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2",
  ".map": "application/json; charset=utf-8",
};

export function contentTypeFor(file: string): string {
  return CONTENT_TYPES[path.extname(file).toLowerCase()] ?? "application/octet-stream";
}

/** Report photos are user uploads (storage.rules accepts any image/*). Only
 *  raster types are passed through, so an uploaded SVG can't run script in
 *  the dashboard's origin. */
const PHOTO_TYPES = new Set(["image/jpeg", "image/png", "image/webp", "image/gif", "image/heic", "image/heif"]);

export function isAllowedPhotoType(contentType: string | undefined): boolean {
  return typeof contentType === "string" && PHOTO_TYPES.has(contentType.split(";")[0].trim().toLowerCase());
}

/** CSP for the dashboard page: own scripts only; OSM tiles; blob: photos. */
export const PAGE_CSP = [
  "default-src 'self'",
  "script-src 'self'",
  "img-src 'self' blob: data: https://tile.openstreetmap.org",
  "style-src 'self' 'unsafe-inline'",
  "connect-src 'self'",
  "frame-ancestors 'none'",
  "base-uri 'none'",
  "form-action 'none'",
].join("; ");
