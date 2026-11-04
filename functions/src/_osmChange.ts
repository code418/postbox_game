// osmChange (.osc) generation + OSM API node lookups for accepted problem
// reports. Shared by the reviewReport callable (reports.ts → one node per
// report) and the local review dashboard's batch exporter (_osmBatch.ts →
// many nodes in one file for a single manual JOSM upload).
//
// Deliberately free of firebase-admin / adminInit so it stays pure and
// importable anywhere. OSM submission itself is never automated (OSM
// automated-edit policy): a human uploads what this builds.

const OSM_NODE_API = "https://api.openstreetmap.org/api/0.6/node";
export const OSM_USER_AGENT = "PostboxGame/1.0 (https://the-postbox-game.web.app)";

function escapeXml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

export interface OsmChangeInput {
  action: "create" | "modify";
  /** OSM node id; pass a negative placeholder (e.g. -1) for create. */
  id: number;
  /** Required for modify (the node's current version); ignored for create. */
  version?: number;
  lat: number;
  lon: number;
  tags: Record<string, string>;
}

function nodeXml(input: OsmChangeInput): string[] {
  const versionAttr = input.action === "modify" ? ` version="${Math.max(1, Math.trunc(input.version ?? 1))}"` : "";
  const tagXml = Object.entries(input.tags)
    .filter(([, v]) => typeof v === "string" && v.length > 0)
    .map(([k, v]) => `      <tag k="${escapeXml(k)}" v="${escapeXml(v)}"/>`)
    .join("\n");
  return [
    `    <node id="${Math.trunc(input.id)}"${versionAttr} lat="${input.lat}" lon="${input.lon}" changeset="0">`,
    ...(tagXml ? [tagXml] : []),
    "    </node>",
  ];
}

/**
 * Builds an osmChange document for any number of node creates/modifies, of the
 * form JOSM accepts: one `<create>` block (in input order) followed by one
 * `<modify>` block. The changeset attribute is left at 0 so the editor fills
 * it in on upload. Callers give each create a distinct negative id.
 */
export function buildOsmChangeBatch(inputs: ReadonlyArray<OsmChangeInput>): string {
  const lines = ['<?xml version="1.0" encoding="UTF-8"?>', '<osmChange version="0.6" generator="PostboxGame">'];
  for (const action of ["create", "modify"] as const) {
    const nodes = inputs.filter((i) => i.action === action);
    if (nodes.length === 0) continue;
    lines.push(`  <${action}>`, ...nodes.flatMap(nodeXml), `  </${action}>`);
  }
  lines.push("</osmChange>", "");
  return lines.join("\n");
}

/**
 * Builds an osmChange (.osc) document for a single node create/modify.
 * Byte-identical to the pre-batch format (pinned by golden tests).
 */
export function buildOsmChange(input: OsmChangeInput): string {
  return buildOsmChangeBatch([input]);
}

export interface OsmNode {
  version: number;
  lat: number;
  lon: number;
  tags: Record<string, string>;
}

/** Outcome of an OSM API node lookup. `status` distinguishes a node that is
 *  gone (404/410) from a network failure, which matters for the batch
 *  exporter: a deleted node can never be modified, a timeout can be retried. */
export type OsmNodeResult =
  | { ok: true; node: OsmNode }
  | { ok: false; status: number | "network" | "malformed" };

type FetchLike = (url: string, init: { headers: Record<string, string> }) => Promise<{
  ok: boolean;
  status: number;
  json(): Promise<unknown>;
}>;

/** Fetches a node from the OSM API. Never throws. `fetchImpl` is a test seam. */
export async function fetchOsmNodeResult(id: number, fetchImpl: FetchLike = fetch): Promise<OsmNodeResult> {
  try {
    const res = await fetchImpl(`${OSM_NODE_API}/${id}.json`, { headers: { "User-Agent": OSM_USER_AGENT } });
    if (!res.ok) return { ok: false, status: res.status };
    const body = (await res.json()) as { elements?: Array<{ type?: string; version?: number; lat?: number; lon?: number; tags?: Record<string, string> }> };
    const node = body.elements?.find((e) => e.type === "node");
    if (!node || typeof node.lat !== "number" || typeof node.lon !== "number") return { ok: false, status: "malformed" };
    return {
      ok: true,
      node: { version: typeof node.version === "number" ? node.version : 1, lat: node.lat, lon: node.lon, tags: node.tags ?? {} },
    };
  } catch (e) {
    console.error("OSM node lookup failed:", e);
    return { ok: false, status: "network" };
  }
}

/** Fetches a node from the OSM API. Returns null on any error (offline, 404, …). */
export async function fetchOsmNode(id: number): Promise<OsmNode | null> {
  const r = await fetchOsmNodeResult(id);
  return r.ok ? r.node : null;
}
