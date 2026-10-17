// Batch OSM follow-up for accepted reports (local review dashboard): merge
// several accepted reports into ONE osmChange file for a single manual JOSM
// upload, then record what was uploaded. Nothing here talks to the OSM write
// API — uploads stay human (OSM automated-edit policy).
//
// Modifies are rebuilt from the node as it is on OSM *now* (fresh version and
// tags), not from the per-report .osc saved at accept time: that file's
// version goes stale as soon as anyone else edits the node, and JOSM would
// then hit a conflict on upload.

import type { firestore } from "firebase-admin";
import type { OsmChangeInput, OsmNodeResult } from "./_osmChange";
import type { OsmBatchEntryDto } from "./_reviewTypes";

/** What the planner needs from an accepted report. */
export interface OsmBatchCandidate {
  reportId: string;
  type: "missing_postbox" | "wrong_cypher";
  /** Review order: later decisions win when merging into a create. */
  reviewedAtMs: number;
  lat?: number;
  lng?: number;
  postboxId?: string;
  overpassId?: number;
  finalMonarch: string | null;
  finalReference?: string;
}

/** An OSM post box this close to a new box's reported spot is treated as the
 *  same box: report GPS is often only good to 25-35 m, and a duplicate node
 *  on OSM is worse than a missing one. */
export const OSM_CREATE_DUPLICATE_M = 30;

/** Whether OSM already has a post box near a create's spot. */
export type CreateCheck =
  | { ok: true; nearest: { id: number; distanceM: number } | null }
  | { ok: false };

export interface OsmBatchPlan {
  inputs: OsmChangeInput[];
  entries: OsmBatchEntryDto[];
}

const MANUAL_PREFIX = "manual_";

function applyCorrection(tags: Record<string, string>, monarch: string | null, reference: string | undefined): Record<string, string> {
  const out = { ...tags };
  if (monarch === null) delete out.royal_cypher;
  else out.royal_cypher = monarch;
  if (reference) out.ref = reference;
  return out;
}

function sameTags(a: Record<string, string>, b: Record<string, string>): boolean {
  const ka = Object.keys(a);
  return ka.length === Object.keys(b).length && ka.every((k) => a[k] === b[k]);
}

/**
 * Pure planner. `fresh` maps each overpassId among the candidates to its
 * current OSM API lookup.
 *  - missing_postbox → a create with ids -1, -2, … in review order, unless
 *    `createChecks` (when given) found an OSM post box within
 *    OSM_CREATE_DUPLICATE_M (already_on_osm) or couldn't look (fetch_failed);
 *  - wrong_cypher on a `manual_<rid>` box whose create is in this batch →
 *    folded into that create's tags (merged_into_create);
 *  - wrong_cypher with an OSM node → one modify per node. Reports on the same
 *    node must agree (else every one is a conflict); a node whose tags would
 *    not change is already_applied; a deleted node is node_missing; a failed
 *    lookup is fetch_failed (retry later);
 *  - anything else (no coordinates, a manual box with no node yet) → no_target.
 */
export function planOsmBatch(
  candidates: ReadonlyArray<OsmBatchCandidate>,
  fresh: ReadonlyMap<number, OsmNodeResult>,
  createChecks?: ReadonlyMap<string, CreateCheck>
): OsmBatchPlan {
  const ordered = [...candidates].sort((a, b) => a.reviewedAtMs - b.reviewedAtMs || a.reportId.localeCompare(b.reportId));
  const entries = new Map<string, OsmBatchEntryDto>();
  const creates = new Map<string, OsmChangeInput>(); // reportId → create input
  const inputs: OsmChangeInput[] = [];

  let nextId = -1;
  for (const c of ordered) {
    if (c.type !== "missing_postbox") continue;
    if (typeof c.lat !== "number" || typeof c.lng !== "number") {
      entries.set(c.reportId, { reportId: c.reportId, action: null, nodeId: null, status: "no_target", detail: "Report has no coordinates." });
      continue;
    }
    const check = createChecks?.get(c.reportId);
    if (createChecks && (!check || !check.ok)) {
      entries.set(c.reportId, { reportId: c.reportId, action: "create", nodeId: null, status: "fetch_failed", detail: "Couldn't check OSM for a box already mapped here. Try again." });
      continue;
    }
    if (check?.ok && check.nearest && check.nearest.distanceM <= OSM_CREATE_DUPLICATE_M) {
      entries.set(c.reportId, {
        reportId: c.reportId,
        action: "create",
        nodeId: check.nearest.id,
        status: "already_on_osm",
        detail: `OSM node ${check.nearest.id} is ${check.nearest.distanceM} m away. If it's a different box, add this one by hand in iD.`,
      });
      continue;
    }
    const input: OsmChangeInput = {
      action: "create",
      id: nextId--,
      lat: c.lat,
      lon: c.lng,
      tags: applyCorrection({ amenity: "post_box" }, c.finalMonarch, c.finalReference),
    };
    creates.set(c.reportId, input);
    inputs.push(input);
    entries.set(c.reportId, { reportId: c.reportId, action: "create", nodeId: input.id, status: "included" });
  }

  const byNode = new Map<number, OsmBatchCandidate[]>();
  for (const c of ordered) {
    if (c.type !== "wrong_cypher") continue;
    const manualOf = c.postboxId?.startsWith(MANUAL_PREFIX) ? c.postboxId.slice(MANUAL_PREFIX.length) : null;
    const create = manualOf !== null ? creates.get(manualOf) : undefined;
    if (create) {
      create.tags = applyCorrection(create.tags, c.finalMonarch, c.finalReference);
      entries.set(c.reportId, { reportId: c.reportId, action: "create", nodeId: create.id, status: "merged_into_create", detail: `Folded into the create from report ${manualOf}.` });
      continue;
    }
    if (typeof c.overpassId !== "number") {
      entries.set(c.reportId, {
        reportId: c.reportId,
        action: null,
        nodeId: null,
        status: "no_target",
        detail: manualOf !== null ? "This box isn't on OSM yet. Upload its create first." : "The box has no OSM node id.",
      });
      continue;
    }
    const group = byNode.get(c.overpassId) ?? [];
    group.push(c);
    byNode.set(c.overpassId, group);
  }

  for (const [nodeId, group] of byNode) {
    const mark = (status: OsmBatchEntryDto["status"], detail?: string) => {
      for (const c of group) entries.set(c.reportId, { reportId: c.reportId, action: "modify", nodeId, status, ...(detail ? { detail } : {}) });
    };
    const monarchs = new Set(group.map((c) => c.finalMonarch));
    const refs = new Set(group.map((c) => c.finalReference).filter((r): r is string => typeof r === "string" && r.length > 0));
    if (monarchs.size > 1 || refs.size > 1) {
      mark("conflict", "Reports on this node disagree. Resolve it by hand.");
      continue;
    }
    const r = fresh.get(nodeId);
    if (!r || !r.ok) {
      const gone = r !== undefined && (r.status === 404 || r.status === 410);
      mark(gone ? "node_missing" : "fetch_failed", gone ? "The node has been deleted on OSM." : "Couldn't fetch the node from OSM. Try again.");
      continue;
    }
    const last = group[group.length - 1];
    const tags = applyCorrection(r.node.tags, last.finalMonarch, last.finalReference);
    if (sameTags(tags, r.node.tags)) {
      mark("already_applied", "OSM already has these tags.");
      continue;
    }
    inputs.push({ action: "modify", id: nodeId, version: r.node.version, lat: r.node.lat, lon: r.node.lon, tags });
    mark("included");
  }

  return {
    inputs,
    entries: candidates.map((c) => entries.get(c.reportId) ?? { reportId: c.reportId, action: null, nodeId: null, status: "no_target" }),
  };
}

/** A changeset comment for the upload, e.g. "Postbox Game: add 2 post boxes, fix 3 royal cyphers". */
export function suggestedChangesetComment(plan: OsmBatchPlan): string {
  const creates = plan.inputs.filter((i) => i.action === "create").length;
  const modifies = plan.inputs.filter((i) => i.action === "modify").length;
  const parts: string[] = [];
  if (creates > 0) parts.push(`add ${creates} post box${creates === 1 ? "" : "es"}`);
  if (modifies > 0) parts.push(`fix ${modifies} royal cypher${modifies === 1 ? "" : "s"}`);
  return `Postbox Game: ${parts.join(", ") || "no changes"} (from player reports, reviewed by hand)`;
}

/** Records that the reviewer uploaded these reports' edits to OSM. */
export async function markOsmUploaded(
  db: firestore.Firestore,
  reviewerUid: string,
  reportIds: ReadonlyArray<string>,
  changesetId: number | null,
  createdNodeIds: Readonly<Record<string, number>>,
  now: unknown
): Promise<void> {
  const batch = db.batch();
  for (const id of reportIds) {
    const update: Record<string, unknown> = { osmUploadedAt: now, osmUploadedBy: reviewerUid };
    if (changesetId !== null) update.osmChangesetId = changesetId;
    if (typeof createdNodeIds[id] === "number") update.osmNodeId = createdNodeIds[id];
    batch.set(db.collection("reports").doc(id), update, { merge: true });
  }
  await batch.commit();
}

/** Takes reports off the pending-OSM list without uploading anything. */
export async function markOsmSkipped(
  db: firestore.Firestore,
  reviewerUid: string,
  reportIds: ReadonlyArray<string>,
  reason: string,
  now: unknown
): Promise<void> {
  const batch = db.batch();
  for (const id of reportIds) {
    batch.set(db.collection("reports").doc(id), { osmSkippedAt: now, osmSkippedBy: reviewerUid, osmSkipReason: reason }, { merge: true });
  }
  await batch.commit();
}
