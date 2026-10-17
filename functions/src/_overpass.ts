// Live OpenStreetMap lookups (Overpass API) for the local review dashboard:
// "what does OSM have near this reported spot right now?". Pure query/parse
// helpers plus a small client that serialises requests and caches answers,
// so a reviewer flicking through reports never hammers the public instance.
// No firebase-admin imports.

import { OSM_USER_AGENT } from "./_osmChange";

/** Same endpoint the daily import (osm_import.sh) uses. */
export const OVERPASS_ENDPOINT = "https://overpass-api.de/api/interpreter";
export const OVERPASS_MIN_RADIUS_M = 1;
export const OVERPASS_MAX_RADIUS_M = 500;
export const OVERPASS_CACHE_TTL_MS = 10 * 60 * 1000;

/** "active" = amenity=post_box; "disused"/"was" = lifecycle-prefixed tags,
 *  i.e. OSM knows a box was there but considers it out of use or removed. */
export type OsmLifecycle = "active" | "disused" | "was";

export interface OverpassNode {
  id: number;
  lat: number;
  lon: number;
  tags: Record<string, string>;
  version?: number;
  timestamp?: string;
  user?: string;
  lifecycle: OsmLifecycle;
}

export function clampOverpassRadius(radiusM: number): number {
  if (!Number.isFinite(radiusM)) return 150;
  return Math.min(OVERPASS_MAX_RADIUS_M, Math.max(OVERPASS_MIN_RADIUS_M, Math.round(radiusM)));
}

/** Overpass QL for every post_box node (active or lifecycle-prefixed) within
 *  radiusM of the point, with meta (version/timestamp/user). */
export function buildOverpassAroundQuery(lat: number, lng: number, radiusM: number): string {
  const around = `around:${clampOverpassRadius(radiusM)},${lat.toFixed(6)},${lng.toFixed(6)}`;
  return [
    "[out:json][timeout:25];",
    "(",
    `  node(${around})[amenity=post_box];`,
    `  node(${around})["disused:amenity"=post_box];`,
    `  node(${around})["was:amenity"=post_box];`,
    ");",
    "out meta;",
  ].join("\n");
}

export function lifecycleOf(tags: Record<string, string>): OsmLifecycle {
  if (tags.amenity === "post_box") return "active";
  if (tags["disused:amenity"] === "post_box") return "disused";
  return "was";
}

/** Parses an Overpass JSON body into nodes, dropping anything malformed. */
export function parseOverpassNodes(body: unknown): OverpassNode[] {
  const elements = (body as { elements?: unknown })?.elements;
  if (!Array.isArray(elements)) return [];
  const out: OverpassNode[] = [];
  for (const raw of elements) {
    const e = raw as Record<string, unknown>;
    if (e?.type !== "node" || typeof e.id !== "number" || typeof e.lat !== "number" || typeof e.lon !== "number") continue;
    const tags: Record<string, string> = {};
    if (e.tags && typeof e.tags === "object") {
      for (const [k, v] of Object.entries(e.tags as Record<string, unknown>)) {
        if (typeof v === "string") tags[k] = v;
      }
    }
    out.push({
      id: e.id,
      lat: e.lat,
      lon: e.lon,
      tags,
      ...(typeof e.version === "number" ? { version: e.version } : {}),
      ...(typeof e.timestamp === "string" ? { timestamp: e.timestamp } : {}),
      ...(typeof e.user === "string" ? { user: e.user } : {}),
      lifecycle: lifecycleOf(tags),
    });
  }
  return out;
}

type PostFetch = (url: string, init: { method: "POST"; headers: Record<string, string>; body: string }) => Promise<{
  ok: boolean;
  status: number;
  json(): Promise<unknown>;
}>;

export interface OverpassResult {
  nodes: OverpassNode[];
  /** Epoch ms the data was fetched from Overpass. */
  fetchedAt: number;
  cached: boolean;
}

export class OverpassError extends Error {
  constructor(message: string, readonly status: number | "network") {
    super(message);
  }
}

/**
 * Overpass client with a per-query TTL cache and strictly one request in
 * flight at a time (the public instance's fair-use policy). Only call it on
 * an explicit user action; never prefetch.
 */
export class OverpassClient {
  private readonly cache = new Map<string, OverpassResult>();
  private queue: Promise<unknown> = Promise.resolve();

  constructor(
    private readonly fetchImpl: PostFetch = fetch as unknown as PostFetch,
    private readonly now: () => number = Date.now,
    private readonly ttlMs: number = OVERPASS_CACHE_TTL_MS,
  ) {}

  nodesAround(lat: number, lng: number, radiusM: number): Promise<OverpassResult> {
    const query = buildOverpassAroundQuery(lat, lng, radiusM);
    const hit = this.cache.get(query);
    if (hit && this.now() - hit.fetchedAt < this.ttlMs) return Promise.resolve({ ...hit, cached: true });
    const run = this.queue.then(() => this.fetchNow(query));
    // Keep the chain alive whatever this request does.
    this.queue = run.catch(() => undefined);
    return run;
  }

  private async fetchNow(query: string): Promise<OverpassResult> {
    // A queued duplicate may have been answered while it waited.
    const hit = this.cache.get(query);
    if (hit && this.now() - hit.fetchedAt < this.ttlMs) return { ...hit, cached: true };
    let res;
    try {
      res = await this.fetchImpl(OVERPASS_ENDPOINT, {
        method: "POST",
        headers: { "User-Agent": OSM_USER_AGENT, "Content-Type": "application/x-www-form-urlencoded" },
        body: `data=${encodeURIComponent(query)}`,
      });
    } catch (e) {
      throw new OverpassError(`Overpass unreachable: ${(e as Error).message}`, "network");
    }
    if (!res.ok) throw new OverpassError(`Overpass returned HTTP ${res.status}`, res.status);
    const result: OverpassResult = { nodes: parseOverpassNodes(await res.json()), fetchedAt: this.now(), cached: false };
    this.cache.set(query, result);
    return result;
  }
}
