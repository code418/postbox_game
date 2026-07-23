import "./adminInit";
import { monitorAppCheck } from "./_appCheck";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions";
import * as geohash from "ngeohash";
import { KNOWN_MONARCHS } from "./_getPoints";
import { getTodayLondon } from "./_dateUtils";
import { countySlug } from "./_leaderboardUtils";
import { getLatLng, MAX_GEOHASH_PRECISION } from "./_lookupPostboxes";
import { containsProfanity } from "./_profanityFilter";
import { rescoreAfterCypherChange } from "./_recomputeScores";
import type { PostboxDoc, ReportPhoto } from "./types";

const NOTE_MAX = 280;
const REFERENCE_MAX = 40;
const MAX_PHOTOS = 3;
/** Per-user cap on accepted submitReport calls per London day. Abuse guard:
 *  a malicious or buggy client can't flood the reports collection (and the
 *  admin review queue / Storage with photos) faster than this. */
const MAX_REPORTS_PER_DAY = 10;
const OSM_NODE_API = "https://api.openstreetmap.org/api/0.6/node";
const OSM_USER_AGENT = "PostboxGame/1.0 (https://the-postbox-game.web.app)";

// ── input validation ────────────────────────────────────────────────────────

function err(message: string): functions.https.HttpsError {
  return new functions.https.HttpsError("invalid-argument", message);
}

/** Returns the validated monarch: undefined (= "not sure"), null (= plain), or a known key. */
function parseSuggestedMonarch(raw: unknown): string | null | undefined {
  if (raw === undefined) return undefined;
  if (raw === null || raw === "") return null;
  if (typeof raw !== "string") throw err("suggestedMonarch must be a string, null, or omitted");
  if (!KNOWN_MONARCHS.includes(raw)) throw err(`suggestedMonarch must be one of: ${KNOWN_MONARCHS.join(", ")}`);
  return raw;
}

function parseNote(raw: unknown): string | undefined {
  if (raw === undefined || raw === null || raw === "") return undefined;
  if (typeof raw !== "string") throw err("note must be a string");
  const note = raw.trim();
  if (note.length === 0) return undefined;
  if (note.length > NOTE_MAX) throw err(`note must be ${NOTE_MAX} characters or fewer`);
  if (containsProfanity(note)) throw err("That note isn't allowed");
  return note;
}

function parseReference(raw: unknown): string | undefined {
  if (raw === undefined || raw === null || raw === "") return undefined;
  if (typeof raw !== "string") throw err("reference must be a string");
  const ref = raw.trim();
  if (ref.length === 0) return undefined;
  if (ref.length > REFERENCE_MAX) throw err(`reference must be ${REFERENCE_MAX} characters or fewer`);
  return ref;
}

function parseLat(raw: unknown): number {
  if (typeof raw !== "number" || !Number.isFinite(raw) || raw < -90 || raw > 90) {
    throw err("lat must be a finite number between -90 and 90");
  }
  return raw;
}
function parseLng(raw: unknown): number {
  if (typeof raw !== "number" || !Number.isFinite(raw) || raw < -180 || raw > 180) {
    throw err("lng must be a finite number between -180 and 180");
  }
  return raw;
}

/**
 * Validates the photos array shape and that each storagePath sits directly
 * under report_photos/{uid}/ (no path traversal). EXIF coordinates, when
 * present, must be plausible. Does not check Storage existence — callers do
 * that separately so this stays pure & unit-testable.
 */
export function parsePhotos(raw: unknown, uid: string): ReportPhoto[] {
  if (raw === undefined || raw === null) return [];
  if (!Array.isArray(raw)) throw err("photos must be an array");
  if (raw.length > MAX_PHOTOS) throw err(`at most ${MAX_PHOTOS} photos are allowed`);
  const prefix = `report_photos/${uid}/`;
  return raw.map((p, i) => {
    if (typeof p !== "object" || p === null) throw err(`photos[${i}] must be an object`);
    const obj = p as Record<string, unknown>;
    const storagePath = obj.storagePath;
    if (typeof storagePath !== "string" || !storagePath.startsWith(prefix)) {
      throw err(`photos[${i}].storagePath must start with ${prefix}`);
    }
    const name = storagePath.slice(prefix.length);
    if (name.length === 0 || name.includes("/") || name.includes("..")) {
      throw err(`photos[${i}].storagePath has an invalid file name`);
    }
    const out: ReportPhoto = { storagePath };
    if (obj.exifLat !== undefined) out.exifLat = parseLat(obj.exifLat);
    if (obj.exifLng !== undefined) out.exifLng = parseLng(obj.exifLng);
    if (obj.takenAt !== undefined) {
      if (typeof obj.takenAt !== "string" || obj.takenAt.length > 40) throw err(`photos[${i}].takenAt must be a short string`);
      out.takenAt = obj.takenAt;
    }
    return out;
  });
}

// ── per-user daily quota ────────────────────────────────────────────────────

export interface QuotaState {
  date: string;
  count: number;
}

/**
 * Pure helper: given the stored quota state for a user (or undefined for a
 * first-ever report), today's London date, and the daily cap, decide whether
 * another report is allowed and return the state to persist.
 *
 * Rolling over to a new day resets the count. When the cap has been hit the
 * returned state is left unchanged (count not incremented) so a rejected
 * attempt doesn't push the stored value past the cap. Exported for unit testing.
 */
export function nextQuotaState(
  current: { date?: unknown; count?: unknown } | undefined,
  today: string,
  max: number
): { allowed: boolean; state: QuotaState } {
  const rawCount = current && current.date === today ? current.count : undefined;
  const prevCount = typeof rawCount === "number" && rawCount > 0 ? Math.floor(rawCount) : 0;
  if (prevCount >= max) {
    return { allowed: false, state: { date: today, count: prevCount } };
  }
  return { allowed: true, state: { date: today, count: prevCount + 1 } };
}

// ── osmChange XML ───────────────────────────────────────────────────────────

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

/**
 * Builds an osmChange (.osc) document for a single node create/modify, of the
 * form JOSM accepts. The changeset attribute is left at 0 so the editor fills
 * it in on upload. Exported for unit testing.
 */
export function buildOsmChange(input: OsmChangeInput): string {
  const versionAttr = input.action === "modify" ? ` version="${Math.max(1, Math.trunc(input.version ?? 1))}"` : "";
  const tagXml = Object.entries(input.tags)
    .filter(([, v]) => typeof v === "string" && v.length > 0)
    .map(([k, v]) => `      <tag k="${escapeXml(k)}" v="${escapeXml(v)}"/>`)
    .join("\n");
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<osmChange version="0.6" generator="PostboxGame">',
    `  <${input.action}>`,
    `    <node id="${Math.trunc(input.id)}"${versionAttr} lat="${input.lat}" lon="${input.lon}" changeset="0">`,
    ...(tagXml ? [tagXml] : []),
    "    </node>",
    `  </${input.action}>`,
    "</osmChange>",
    "",
  ].join("\n");
}

interface OsmNode {
  version: number;
  lat: number;
  lon: number;
  tags: Record<string, string>;
}

/** Fetches a node from the OSM API. Returns null on any error (offline, 404, …). */
async function fetchOsmNode(id: number): Promise<OsmNode | null> {
  try {
    const res = await fetch(`${OSM_NODE_API}/${id}.json`, { headers: { "User-Agent": OSM_USER_AGENT } });
    if (!res.ok) return null;
    const body = (await res.json()) as { elements?: Array<{ type?: string; version?: number; lat?: number; lon?: number; tags?: Record<string, string> }> };
    const node = body.elements?.find((e) => e.type === "node");
    if (!node || typeof node.lat !== "number" || typeof node.lon !== "number") return null;
    return { version: typeof node.version === "number" ? node.version : 1, lat: node.lat, lon: node.lon, tags: node.tags ?? {} };
  } catch (e) {
    console.error("OSM node lookup failed:", e);
    return null;
  }
}

// ── callables ───────────────────────────────────────────────────────────────

interface SubmitReportData {
  type?: string;
  note?: unknown;
  photos?: unknown;
  lat?: unknown;
  lng?: unknown;
  accuracyMeters?: unknown;
  postboxId?: unknown;
  suggestedMonarch?: unknown;
  suggestedReference?: unknown;
}

export const submitReport = functions.https.onCall(async (request) => {
  monitorAppCheck(request, "submitReport");
  const uid = request.auth?.uid;
  if (!uid) throw new functions.https.HttpsError("unauthenticated", "Must be signed in to report a problem");

  const data = (request.data as SubmitReportData) ?? {};
  const type = data.type;
  if (type !== "missing_postbox" && type !== "wrong_cypher") {
    throw err("type must be 'missing_postbox' or 'wrong_cypher'");
  }

  const note = parseNote(data.note);
  const photos = parsePhotos(data.photos, uid);
  const suggestedMonarch = parseSuggestedMonarch(data.suggestedMonarch);
  const suggestedReference = parseReference(data.suggestedReference);

  // Verify the referenced photo blobs actually exist in Storage.
  if (photos.length > 0) {
    const bucket = admin.storage().bucket();
    const exists = await Promise.all(photos.map((p) => bucket.file(p.storagePath).exists().then((r) => r[0]).catch(() => false)));
    const missing = photos.filter((_, i) => !exists[i]);
    if (missing.length > 0) throw err("one or more photo uploads were not found in storage");
  }

  const db = admin.firestore();
  const base: Record<string, unknown> = {
    type,
    status: "pending",
    reporterUid: uid,
    createdAt: admin.firestore.Timestamp.now(),
    photos,
  };
  if (note) base.note = note;
  if (suggestedReference) base.suggestedReference = suggestedReference;
  if (suggestedMonarch !== undefined) base.suggestedMonarch = suggestedMonarch;

  if (type === "missing_postbox") {
    base.lat = parseLat(data.lat);
    base.lng = parseLng(data.lng);
    if (data.accuracyMeters !== undefined && data.accuracyMeters !== null) {
      const acc = data.accuracyMeters;
      if (typeof acc !== "number" || !Number.isFinite(acc) || acc < 0) throw err("accuracyMeters must be a non-negative number");
      base.accuracyMeters = acc;
    }
  } else {
    const postboxId = data.postboxId;
    if (typeof postboxId !== "string" || postboxId.length === 0 || postboxId.includes("/")) throw err("postboxId is required");
    const pbSnap = await db.collection("postbox").doc(postboxId).get();
    if (!pbSnap.exists) throw new functions.https.HttpsError("not-found", "That postbox no longer exists");
    const pb = pbSnap.data() as PostboxDoc;
    base.postboxId = postboxId;
    if (typeof pb.overpass_id === "number") base.overpassId = pb.overpass_id;
    base.currentMonarch = typeof pb.monarch === "string" ? pb.monarch : null;
    // A cypher report has to say *something*: a suggested cypher (incl. "plain"),
    // a note, or photo evidence.
    if (suggestedMonarch === undefined && !note && photos.length === 0) {
      throw err("a cypher report needs a suggested cypher, a note, or a photo");
    }
  }

  // Per-user daily cap. Done in a transaction so two concurrent submissions
  // can't both slip past the limit, and only once all validation has passed so
  // a malformed request never consumes a user's quota.
  const today = getTodayLondon();
  const quotaRef = db.collection("reportQuotas").doc(uid);
  // Generate the report ref up front so its id is stable across transaction
  // retries (and can be returned to the caller without an extra round-trip).
  const reportRef = db.collection("reports").doc();
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(quotaRef);
    const r = nextQuotaState(snap.data() as { date?: unknown; count?: unknown } | undefined, today, MAX_REPORTS_PER_DAY);
    if (!r.allowed) {
      throw new functions.https.HttpsError(
        "resource-exhausted",
        `You've reached the daily limit of ${MAX_REPORTS_PER_DAY} reports. Please try again tomorrow.`
      );
    }
    tx.set(quotaRef, r.state, { merge: false });
    // Write the report inside the same transaction as the quota increment so
    // the two commit atomically: a failed report write can no longer burn a
    // user's daily quota, and a committed quota slot always has a stored report.
    tx.set(reportRef, base);
  });

  return { reportId: reportRef.id };
});

interface ReviewReportData {
  reportId?: unknown;
  decision?: unknown;
  reviewNote?: unknown;
  finalMonarch?: unknown;
  finalReference?: unknown;
}

export const reviewReport = functions.https.onCall({ timeoutSeconds: 300 }, async (request) => {
  monitorAppCheck(request, "reviewReport");
  if (request.auth?.token?.admin !== true) {
    throw new functions.https.HttpsError("permission-denied", "Admin access required");
  }
  const adminUid = request.auth.uid;

  const data = (request.data as ReviewReportData) ?? {};
  const reportId = data.reportId;
  if (typeof reportId !== "string" || reportId.length === 0 || reportId.includes("/")) throw err("reportId is required");
  const decision = data.decision;
  if (decision !== "accept" && decision !== "reject") throw err("decision must be 'accept' or 'reject'");
  const reviewNote = parseNote(data.reviewNote);

  const db = admin.firestore();
  const reportRef = db.collection("reports").doc(reportId);
  const reportSnap = await reportRef.get();
  if (!reportSnap.exists) throw new functions.https.HttpsError("not-found", "Report not found");
  const report = reportSnap.data() as {
    type: "missing_postbox" | "wrong_cypher";
    status: string;
    postboxId?: string;
    overpassId?: number;
    lat?: number;
    lng?: number;
    suggestedMonarch?: string | null;
    suggestedReference?: string;
  };
  if (report.status !== "pending") {
    throw new functions.https.HttpsError("failed-precondition", `Report already ${report.status}`);
  }

  const now = admin.firestore.Timestamp.now();

  if (decision === "reject") {
    const update: Record<string, unknown> = { status: "rejected", reviewedBy: adminUid, reviewedAt: now };
    if (reviewNote) update.reviewNote = reviewNote;
    await reportRef.set(update, { merge: true });
    return { status: "rejected" };
  }

  // ── accept ────────────────────────────────────────────────────────────────
  const finalMonarch = parseSuggestedMonarch(data.finalMonarch === undefined ? report.suggestedMonarch : data.finalMonarch);
  const finalReference = parseReference(data.finalReference === undefined ? report.suggestedReference : data.finalReference);
  const today = getTodayLondon();

  let osmEditUrl = "https://www.openstreetmap.org/edit";
  let osmChangesetPath: string | undefined;
  let osmStatus: "changeset_generated" | "changeset_failed" = "changeset_failed";
  let rescoredClaims = 0;
  let affectedUsers = 0;

  if (report.type === "wrong_cypher") {
    if (finalMonarch === undefined) throw err("a cypher correction must specify finalMonarch (a key, or null for plain)");
    const postboxKey = report.postboxId;
    if (typeof postboxKey !== "string") throw new functions.https.HttpsError("failed-precondition", "report is missing postboxId");
    const pbRef = db.collection("postbox").doc(postboxKey);
    const pbSnap = await pbRef.get();
    if (!pbSnap.exists) throw new functions.https.HttpsError("not-found", "That postbox no longer exists");
    const pb = pbSnap.data() as PostboxDoc;
    const overpassId = typeof pb.overpass_id === "number" ? pb.overpass_id : (typeof report.overpassId === "number" ? report.overpassId : undefined);
    const countyName = typeof pb.county === "string" ? pb.county : null;

    const pbUpdate: Record<string, unknown> = { correctedBy: adminUid, correctedAt: now };
    pbUpdate.monarch = finalMonarch === null ? admin.firestore.FieldValue.delete() : finalMonarch;
    if (finalReference) pbUpdate.reference = finalReference;
    // Accepting a cypher correction is implicit confirmation that the postbox
    // still exists: if it had been soft-pruned by a stale OSM extract, clear
    // the flag so it's claimable again. The next OSM import will reapply the
    // flag only if the node is still missing upstream.
    if (pb.removedFromOsm === true) {
      pbUpdate.removedFromOsm = admin.firestore.FieldValue.delete();
      pbUpdate.removedFromOsmAt = admin.firestore.FieldValue.delete();
    }
    await pbRef.set(pbUpdate, { merge: true });

    // Always rewrite the claims' stored monarch; this also recomputes affected
    // users' totals and leaderboards (a no-op for totals when the new cypher
    // maps to the same points value as the old one).
    const r = await rescoreAfterCypherChange(db, postboxKey, finalMonarch, countyName ? countySlug(countyName) : null, countyName, today);
    rescoredClaims = r.rescoredClaims;
    affectedUsers = r.affectedUsers;

    if (overpassId !== undefined) {
      osmEditUrl = `https://www.openstreetmap.org/edit?editor=id&node=${overpassId}`;
      const node = await fetchOsmNode(overpassId);
      if (node) {
        const tags = { ...node.tags };
        if (finalMonarch === null) delete tags.royal_cypher;
        else tags.royal_cypher = finalMonarch;
        if (finalReference) tags.ref = finalReference;
        const osc = buildOsmChange({ action: "modify", id: overpassId, version: node.version, lat: node.lat, lon: node.lon, tags });
        osmChangesetPath = `osm_changesets/${reportId}.osc`;
        try {
          await admin.storage().bucket().file(osmChangesetPath).save(osc, { contentType: "application/xml" });
          osmStatus = "changeset_generated";
        } catch (e) {
          console.error("osmChange upload failed:", e);
          osmChangesetPath = undefined;
        }
      }
    } else {
      const geo = getLatLng(pb.geopoint);
      if (geo) osmEditUrl = `https://www.openstreetmap.org/edit#map=19/${geo.lat}/${geo.lng}`;
    }
  } else {
    // missing_postbox → create a postbox doc + a node-create changeset.
    const lat = typeof report.lat === "number" ? report.lat : NaN;
    const lng = typeof report.lng === "number" ? report.lng : NaN;
    if (!Number.isFinite(lat) || !Number.isFinite(lng)) throw new functions.https.HttpsError("failed-precondition", "report is missing coordinates");
    const newKey = `manual_${reportId}`;
    const pbRef = db.collection("postbox").doc(newKey);
    // Idempotency: an earlier reviewReport run for this report may have
    // already created the postbox doc but then failed to mark the report
    // accepted. Without this check, an admin retry would re-increment
    // meta/stats.totalPostboxes per attempt and silently inflate the
    // denominator.
    const existing = await pbRef.get();
    const isNewBox = !existing.exists;
    const pbData: Record<string, unknown> = {
      // Encode at the canonical max precision so prefix-queries
      // (_lookupPostboxes / routePostboxes) match this doc — see
      // MAX_GEOHASH_PRECISION docs.
      geohash: geohash.encode(lat, lng, MAX_GEOHASH_PRECISION),
      geopoint: new admin.firestore.GeoPoint(lat, lng),
      source: "user_report",
      reportId,
    };
    if (typeof finalMonarch === "string") pbData.monarch = finalMonarch;
    if (finalReference) pbData.reference = finalReference;
    // Tag the county so future claims on this box flow into county
    // leaderboards. Without this, startScoring's per-county aggregation
    // would skip the box (it bails when `county` is absent), leaving these
    // user-reported boxes invisible on the county heatmap / lifetime-by-county
    // rankings even after claims accumulate.
    //
    // Lazy-require so other functions sharing this module (nearbyPostboxes,
    // startScoring, …) don't pay the ~900 kB GeoJSON parse on their cold
    // starts. The util's own `_features` cache then keeps subsequent calls
    // within a single warm reviewReport instance cheap.
    try {
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      const counties = require("../util/county_lookup") as {
        countyForPoint: (lat: number, lng: number) => string | null;
      };
      const county = counties.countyForPoint(lat, lng);
      if (county) pbData.county = county;
    } catch (e) {
      // County lookup is best-effort: NI postboxes legitimately lack a
      // county, the GeoJSON could be missing in some packaging configurations,
      // etc. Fall through without tagging rather than blocking the accept.
      console.error("county lookup failed (non-fatal):", e);
    }
    await pbRef.set(pbData);
    // Keep the lifetime leaderboard's "X of Y boxes (Z%)" denominator
    // accurate immediately rather than waiting for the next OSM reimport.
    // Only fire on first creation so retries don't double-count.
    if (isNewBox) {
      try {
        await db.collection("meta").doc("stats").set(
          { totalPostboxes: admin.firestore.FieldValue.increment(1) },
          { merge: true }
        );
      } catch (e) {
        console.error("meta/stats.totalPostboxes increment failed:", e);
      }
    }

    const tags: Record<string, string> = { amenity: "post_box" };
    if (typeof finalMonarch === "string") tags.royal_cypher = finalMonarch;
    if (finalReference) tags.ref = finalReference;
    const osc = buildOsmChange({ action: "create", id: -1, lat, lon: lng, tags });
    osmChangesetPath = `osm_changesets/${reportId}.osc`;
    try {
      await admin.storage().bucket().file(osmChangesetPath).save(osc, { contentType: "application/xml" });
      osmStatus = "changeset_generated";
    } catch (e) {
      console.error("osmChange upload failed:", e);
      osmChangesetPath = undefined;
    }
    osmEditUrl = `https://www.openstreetmap.org/edit#map=19/${lat}/${lng}`;
  }

  const update: Record<string, unknown> = {
    status: "accepted",
    reviewedBy: adminUid,
    reviewedAt: now,
    appliedToFirestore: true,
    osmStatus,
    osmEditUrl,
    finalMonarch: finalMonarch ?? null,
  };
  if (reviewNote) update.reviewNote = reviewNote;
  if (finalReference) update.finalReference = finalReference;
  if (osmChangesetPath) update.osmChangesetPath = osmChangesetPath;
  await reportRef.set(update, { merge: true });

  return { status: "accepted", osmEditUrl, osmChangesetPath: osmChangesetPath ?? null, rescoredClaims, affectedUsers };
});
