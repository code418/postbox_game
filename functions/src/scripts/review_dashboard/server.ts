// The local review dashboard's HTTP server. Loaded by main.ts only after the
// project id is in the environment, because importing adminInit initialises
// the Admin SDK. Every accept/reject goes through performReview — the same
// code the reviewReport callable runs.

import "../../adminInit";
import * as admin from "firebase-admin";
import * as fs from "fs";
import * as http from "http";
import { URL } from "url";
import { KNOWN_MONARCHS } from "../../_getPoints";
import { getGameConfig, loadGameConfigFromRemoteConfig, resolvePointsForMonarch, setConfigLoader } from "../../_config";
import { performReview, REJECT_PRESETS, REVIEW_LIMITS, type ReviewReportInput } from "../../reports";
import { previewCypherImpact } from "../../_cypherImpact";
import { assessOsmNodes, buildMapContext, buildReporterContext, CONTEXT_RADIUS_M, toMs, type StoredReport } from "../../_reportContext";
import { OverpassClient, clampOverpassRadius } from "../../_overpass";
import { queryPostboxesNear } from "../../_postboxQuery";
import { buildOsmChangeBatch, fetchOsmNodeResult, type OsmNodeResult } from "../../_osmChange";
import { markOsmSkipped, markOsmUploaded, planOsmBatch, suggestedChangesetComment, type OsmBatchCandidate } from "../../_osmBatch";
import { metresBetween } from "../../_routePlanner";
import { getLatLng } from "../../_geo";
import type {
  BatchItemResultDto,
  OsmBatchDto,
  OsmNearbyDto,
  ReportSummaryDto,
  SessionDto,
} from "../../_reviewTypes";
import type { PostboxDoc } from "../../types";
import { ReportsStore } from "./reportsStore";
import { isOsmPending, pendingOrder, historyOrder, selectHistory, toDetail, toSummary, type HistoryQuery } from "./_dto";
import {
  API_HEADERS,
  HttpError,
  matchRoute,
  readJsonBody,
  requireId,
  requireIds,
  sendError,
  sendJson,
  toHttpError,
  type Route,
} from "./_http";
import {
  PAGE_CSP,
  TOKEN_HEADER,
  allowedOrigins,
  contentTypeFor,
  isAllowedFetchSite,
  isAllowedHost,
  isAllowedOrigin,
  isAllowedPhotoType,
  isJsonContentType,
  resolveStaticPath,
  tokenMatches,
} from "./_security";

export interface ServerOptions {
  port: number;
  projectId: string;
  /** Reviewer uid or email; must hold the `admin` custom claim. */
  reviewer: string;
  /** Vite dev server port when running with --dev (allowed as an Origin). */
  devPort: number | null;
  ignoreMaintenance: boolean;
  token: string;
  staticDir: string;
}

export interface RunningServer {
  reviewer: { uid: string; displayName: string | null };
  pointsOverrideActive: boolean;
  maintenanceMode: boolean;
  reportCount: number;
  close(): Promise<void>;
}

/** A startup failure with advice for the operator. */
export class StartupError extends Error {
  constructor(message: string, readonly hint?: string) {
    super(message);
  }
}

const REVIEWER_RECHECK_MS = 10 * 60 * 1000;
const MAX_BATCH_REJECT = 50;
const MAX_OSM_BATCH = 100;
const OSM_FETCH_CONCURRENCY = 4;
const CREDENTIALS_HINT =
  "Point GOOGLE_APPLICATION_CREDENTIALS at a service-account key for the project, or run\n" +
  "`gcloud auth application-default login` then\n" +
  "`gcloud auth application-default set-quota-project the-postbox-game`.";

async function mapWithConcurrency<T, R>(items: ReadonlyArray<T>, limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const i = next++;
      // Sequential within a worker by design: caps requests in flight.
      // eslint-disable-next-line no-await-in-loop
      out[i] = await fn(items[i]);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return out;
}

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);

export async function startServer(opts: ServerOptions): Promise<RunningServer> {
  const db = admin.firestore();
  const auth = admin.auth();
  const bucket = admin.storage().bucket();

  // Never score with silent fallbacks (see loadGameConfigFromRemoteConfig).
  setConfigLoader(loadGameConfigFromRemoteConfig);

  // ── startup checks ───────────────────────────────────────────────────────
  let reviewerRecord: admin.auth.UserRecord;
  try {
    reviewerRecord = opts.reviewer.includes("@") ? await auth.getUserByEmail(opts.reviewer) : await auth.getUser(opts.reviewer);
  } catch (e) {
    const code = (e as { code?: string }).code;
    if (code === "auth/user-not-found") throw new StartupError(`No Firebase Auth user matches --reviewer ${opts.reviewer}.`);
    throw new StartupError(`Couldn't reach Firebase Auth: ${(e as Error).message}`, CREDENTIALS_HINT);
  }
  if (reviewerRecord.customClaims?.admin !== true) {
    throw new StartupError(
      `${opts.reviewer} doesn't have the admin claim.`,
      `Grant it with: node set_admin.js ${reviewerRecord.uid} --project ${opts.projectId}`,
    );
  }
  const reviewerUid = reviewerRecord.uid;
  let config;
  try {
    config = await getGameConfig();
  } catch (e) {
    throw new StartupError(`Couldn't load the Remote Config template: ${(e as Error).message}`, CREDENTIALS_HINT);
  }
  try {
    const [exists] = await bucket.exists();
    if (!exists) throw new Error(`bucket ${bucket.name} not found`);
  } catch (e) {
    throw new StartupError(`Couldn't reach Cloud Storage: ${(e as Error).message}`, CREDENTIALS_HINT);
  }

  const store = new ReportsStore(db);
  try {
    await store.start();
  } catch (e) {
    throw new StartupError(`Couldn't listen to the reports collection: ${(e as Error).message}`, CREDENTIALS_HINT);
  }
  const reviewerNames = await store.resolveNames([reviewerUid]);
  const reviewer = { uid: reviewerUid, displayName: reviewerNames.get(reviewerUid) ?? reviewerRecord.displayName ?? null };

  const overpass = new OverpassClient();
  const origins = allowedOrigins(opts.port, opts.devPort);
  let reviewerCheckedAt = Date.now();

  // ── write guards ─────────────────────────────────────────────────────────
  async function assertReviewer(): Promise<void> {
    if (Date.now() - reviewerCheckedAt < REVIEWER_RECHECK_MS) return;
    const u = await auth.getUser(reviewerUid);
    if (u.customClaims?.admin !== true) {
      throw new HttpError(403, "permission-denied", "The reviewer account no longer has the admin claim.");
    }
    reviewerCheckedAt = Date.now();
  }

  /** Mirrors the app's MaintenanceGuard, which gates in-app reviews. */
  async function assertNotMaintenance(): Promise<void> {
    if ((await getGameConfig()).maintenanceMode && !opts.ignoreMaintenance) {
      throw new HttpError(503, "unavailable", "Maintenance mode is on, so reviews are paused. Restart with --ignore-maintenance to review anyway.");
    }
  }

  // ── helpers ──────────────────────────────────────────────────────────────
  async function summaries(rows: StoredReport[]): Promise<ReportSummaryDto[]> {
    await store.resolveBoxPositions(
      rows.filter((r) => r.data.type === "wrong_cypher" && typeof r.data.postboxId === "string").map((r) => r.data.postboxId as string),
    );
    const names = await store.resolveNames(
      rows.flatMap((r) => [r.data.reporterUid, ...(typeof r.data.reviewedBy === "string" ? [r.data.reviewedBy] : [])]),
    );
    return rows.map((r) => toSummary(r, names, store.boxPositions));
  }

  async function findReport(rawId: string | undefined): Promise<StoredReport> {
    const id = requireId(rawId, "report id");
    const r = store.get(id) ?? (await store.refresh(id));
    if (!r) throw new HttpError(404, "not-found", "Report not found");
    return r;
  }

  async function anchorOf(r: StoredReport): Promise<{ lat: number; lng: number } | null> {
    if (r.data.type === "missing_postbox") {
      return typeof r.data.lat === "number" && typeof r.data.lng === "number" ? { lat: r.data.lat, lng: r.data.lng } : null;
    }
    if (typeof r.data.postboxId !== "string") return null;
    await store.resolveBoxPositions([r.data.postboxId]);
    return store.boxPositions.get(r.data.postboxId) ?? null;
  }

  function logWrite(msg: string): void {
    console.log(`[review ${new Date().toISOString()}] ${msg}`);
  }

  // ── routes ───────────────────────────────────────────────────────────────
  const routes: Route[] = [
    {
      method: "GET",
      pattern: /^\/api\/session$/,
      handler: async ({ res }) => {
        const cfg = await getGameConfig();
        const body: SessionDto = {
          reviewer,
          projectId: opts.projectId,
          monarchs: KNOWN_MONARCHS.map((key) => ({ key, points: resolvePointsForMonarch(cfg, key) })),
          plainPoints: resolvePointsForMonarch(cfg, null),
          pointsOverrideActive: cfg.pointsOverride !== null,
          maintenanceMode: cfg.maintenanceMode,
          ignoreMaintenance: opts.ignoreMaintenance,
          noteMax: REVIEW_LIMITS.noteMax,
          referenceMax: REVIEW_LIMITS.referenceMax,
          rejectPresets: [...REJECT_PRESETS],
          storeReady: store.ready,
        };
        sendJson(res, 200, body);
      },
    },
    {
      method: "GET",
      pattern: /^\/api\/reports$/,
      handler: async ({ res, query }) => {
        const status = query.get("status") ?? "pending";
        if (status !== "pending") throw new HttpError(400, "invalid-argument", "Use /api/reports/history for reviewed reports");
        const rows = store.all().filter((r) => r.data.status === "pending").sort(pendingOrder);
        sendJson(res, 200, { reports: await summaries(rows) });
      },
    },
    {
      method: "GET",
      pattern: /^\/api\/reports\/history$/,
      handler: async ({ res, query }) => {
        const status = query.get("status") ?? "all";
        const type = query.get("type") ?? "all";
        if (status !== "accepted" && status !== "rejected" && status !== "all") throw new HttpError(400, "invalid-argument", "Bad status");
        if (type !== "missing_postbox" && type !== "wrong_cypher" && type !== "all") throw new HttpError(400, "invalid-argument", "Bad type");
        const before = query.get("before");
        const limit = Number(query.get("limit") ?? 50);
        const q: HistoryQuery = {
          status,
          type,
          beforeMs: before !== null && Number.isFinite(Number(before)) ? Number(before) : null,
          limit: Number.isInteger(limit) && limit >= 1 && limit <= 200 ? limit : 50,
        };
        const page = selectHistory(store.all(), q);
        sendJson(res, 200, { reports: await summaries(page.reports), nextBefore: page.nextBefore });
      },
    },
    {
      method: "POST",
      pattern: /^\/api\/reports\/batch-reject$/,
      handler: async ({ req, res }) => {
        await assertReviewer();
        await assertNotMaintenance();
        const body = await readJsonBody(req);
        if (!isObject(body)) throw new HttpError(400, "invalid-argument", "Expected a JSON object");
        const ids = requireIds(body.reportIds, MAX_BATCH_REJECT);
        const settled = await Promise.allSettled(
          ids.map((reportId) => performReview(db, bucket, reviewerUid, { reportId, decision: "reject", reviewNote: body.reviewNote })),
        );
        await Promise.all(ids.map((id) => store.refresh(id)));
        const results: BatchItemResultDto[] = settled.map((s, i) => {
          if (s.status === "fulfilled") return { reportId: ids[i], ok: true };
          const e = toHttpError(s.reason);
          return { reportId: ids[i], ok: false, code: e.code, message: e.message };
        });
        logWrite(`batch reject by ${reviewerUid}: ${results.filter((r) => r.ok).length}/${ids.length} rejected`);
        sendJson(res, 200, { results });
      },
    },
    {
      method: "GET",
      pattern: /^\/api\/reports\/([^/]+)$/,
      handler: async ({ res, params }) => {
        const r = await findReport(params[0]);
        let postbox: { id: string; data: PostboxDoc & Record<string, unknown> } | null = null;
        if (r.data.type === "wrong_cypher" && typeof r.data.postboxId === "string") {
          const snap = await db.collection("postbox").doc(r.data.postboxId).get();
          if (snap.exists) {
            postbox = { id: snap.id, data: snap.data() as PostboxDoc & Record<string, unknown> };
            const pos = getLatLng(postbox.data.geopoint);
            if (pos) store.boxPositions.set(snap.id, pos);
          }
        }
        const names = await store.resolveNames([r.data.reporterUid, ...(typeof r.data.reviewedBy === "string" ? [r.data.reviewedBy] : [])]);
        sendJson(res, 200, toDetail(r, names, store.boxPositions, postbox));
      },
    },
    {
      method: "GET",
      pattern: /^\/api\/reports\/([^/]+)\/context$/,
      handler: async ({ res, params }) => {
        const r = await findReport(params[0]);
        const all = store.all();
        const [map, reporter] = await Promise.all([
          buildMapContext(db, r, all, store.boxPositions),
          buildReporterContext(db, auth, r.data.reporterUid, all, r.data.type === "wrong_cypher" && typeof r.data.postboxId === "string" ? r.data.postboxId : null),
        ]);
        sendJson(res, 200, { map, reporter });
      },
    },
    {
      method: "GET",
      pattern: /^\/api\/reports\/([^/]+)\/osm-nearby$/,
      handler: async ({ res, params, query }) => {
        const r = await findReport(params[0]);
        const anchor = await anchorOf(r);
        if (!anchor) throw new HttpError(409, "failed-precondition", "This report has no location to search around");
        const radius = clampOverpassRadius(Number(query.get("radius") ?? CONTEXT_RADIUS_M));
        const [result, stored] = await Promise.all([
          overpass.nodesAround(anchor.lat, anchor.lng, radius),
          queryPostboxesNear(db, anchor.lat, anchor.lng, radius),
        ]);
        const byOverpassId = new Map<number, string>();
        for (const pb of stored) if (typeof pb.data.overpass_id === "number") byOverpassId.set(pb.data.overpass_id, pb.id);
        const nodes = result.nodes
          .map((n) => ({
            id: n.id,
            lat: n.lat,
            lon: n.lon,
            tags: n.tags,
            version: n.version ?? null,
            timestamp: n.timestamp ?? null,
            user: n.user ?? null,
            lifecycle: n.lifecycle,
            distanceM: metresBetween(anchor, { lat: n.lat, lng: n.lon }),
            firestoreId: byOverpassId.get(n.id) ?? null,
          }))
          .sort((a, b) => a.distanceM - b.distanceM);
        const body: OsmNearbyDto = {
          nodes,
          fetchedAtMs: result.fetchedAt,
          cached: result.cached,
          flags: assessOsmNodes(
            {
              type: r.data.type,
              postboxId: typeof r.data.postboxId === "string" ? r.data.postboxId : null,
              hasSuggestedMonarch: "suggestedMonarch" in r.data && r.data.suggestedMonarch !== undefined,
              suggestedMonarch: typeof r.data.suggestedMonarch === "string" ? r.data.suggestedMonarch : null,
            },
            nodes,
          ),
        };
        sendJson(res, 200, body);
      },
    },
    {
      method: "GET",
      pattern: /^\/api\/reports\/([^/]+)\/impact$/,
      handler: async ({ res, params, query }) => {
        const r = await findReport(params[0]);
        if (r.data.type !== "wrong_cypher" || typeof r.data.postboxId !== "string") {
          throw new HttpError(400, "invalid-argument", "Impact previews are for cypher reports");
        }
        const raw = query.get("finalMonarch");
        if (raw !== "plain" && (raw === null || !KNOWN_MONARCHS.includes(raw))) {
          throw new HttpError(400, "invalid-argument", "finalMonarch must be a known cypher or 'plain'");
        }
        sendJson(res, 200, await previewCypherImpact(db, r.data.postboxId, raw === "plain" ? null : raw));
      },
    },
    {
      method: "GET",
      pattern: /^\/api\/reports\/([^/]+)\/photos\/(\d+)$/,
      handler: async ({ res, params }) => {
        const r = await findReport(params[0]);
        const photos = Array.isArray(r.data.photos) ? r.data.photos : [];
        const photo = photos[Number(params[1])];
        // The path always comes from the stored report, never from the client.
        const storagePath = photo?.storagePath;
        if (typeof storagePath !== "string" || !storagePath.startsWith("report_photos/") || storagePath.includes("..")) {
          throw new HttpError(404, "not-found", "No such photo");
        }
        const file = bucket.file(storagePath);
        let meta;
        try {
          [meta] = await file.getMetadata();
        } catch {
          throw new HttpError(404, "not-found", "The photo is no longer in Storage");
        }
        if (!isAllowedPhotoType(meta.contentType)) throw new HttpError(415, "unsupported-media-type", `Not shown: ${meta.contentType ?? "unknown type"}`);
        res.writeHead(200, {
          "Content-Type": String(meta.contentType),
          ...(meta.size !== undefined ? { "Content-Length": String(meta.size) } : {}),
          "Cache-Control": "private, max-age=600",
          "Content-Security-Policy": "sandbox; default-src 'none'",
          "X-Content-Type-Options": "nosniff",
        });
        await new Promise<void>((resolve) => {
          file.createReadStream()
            .on("error", (e) => {
              console.error(`[review-dashboard] photo stream failed for ${storagePath}:`, e.message);
              res.destroy();
              resolve();
            })
            .on("end", () => resolve())
            .pipe(res);
        });
      },
    },
    {
      method: "GET",
      pattern: /^\/api\/reports\/([^/]+)\/osc$/,
      handler: async ({ res, params }) => {
        const r = await findReport(params[0]);
        const p = r.data.osmChangesetPath;
        if (typeof p !== "string" || !p.startsWith("osm_changesets/") || p.includes("..")) throw new HttpError(404, "not-found", "No .osc for this report");
        let buf: Buffer;
        try {
          [buf] = await bucket.file(p).download();
        } catch {
          throw new HttpError(404, "not-found", "The .osc is no longer in Storage");
        }
        res.writeHead(200, {
          ...API_HEADERS,
          "Content-Type": "application/xml; charset=utf-8",
          "Content-Disposition": `attachment; filename="report-${r.id}.osc"`,
        });
        res.end(buf);
      },
    },
    {
      method: "POST",
      pattern: /^\/api\/reports\/([^/]+)\/review$/,
      handler: async ({ req, res, params }) => {
        const reportId = requireId(params[0], "report id");
        await assertReviewer();
        await assertNotMaintenance();
        const body = await readJsonBody(req);
        if (!isObject(body)) throw new HttpError(400, "invalid-argument", "Expected a JSON object");
        // Copy only known keys, preserving "absent" (falls back to the
        // reporter's suggestion) versus an explicit null / "".
        const data: ReviewReportInput = { reportId, decision: body.decision, reviewNote: body.reviewNote };
        if ("finalMonarch" in body) data.finalMonarch = body.finalMonarch;
        if ("finalReference" in body) data.finalReference = body.finalReference;
        const result = await performReview(db, bucket, reviewerUid, data);
        await store.refresh(reportId);
        logWrite(
          result.status === "accepted"
            ? `accepted ${reportId} by ${reviewerUid}: rescored ${result.rescoredClaims} claims / ${result.affectedUsers} users (${result.rescoreTotalDelta >= 0 ? "+" : ""}${result.rescoreTotalDelta} pts), osc ${result.osmChangesetPath ?? "not generated"}`
            : `rejected ${reportId} by ${reviewerUid}`,
        );
        sendJson(res, 200, result);
      },
    },
    {
      method: "GET",
      pattern: /^\/api\/osm\/pending$/,
      handler: async ({ res }) => {
        const rows = store.all().filter(isOsmPending).sort((a, b) => historyOrder(b, a));
        sendJson(res, 200, { reports: await summaries(rows) });
      },
    },
    {
      method: "POST",
      pattern: /^\/api\/osm\/batch$/,
      handler: async ({ req, res }) => {
        await assertReviewer();
        const body = await readJsonBody(req);
        if (!isObject(body)) throw new HttpError(400, "invalid-argument", "Expected a JSON object");
        const ids = requireIds(body.reportIds, MAX_OSM_BATCH);
        const rows = ids.map((id) => store.get(id));
        const bad = ids.filter((id, i) => !rows[i] || !isOsmPending(rows[i] as StoredReport));
        if (bad.length > 0) throw new HttpError(400, "invalid-argument", `Not awaiting an OSM upload: ${bad.join(", ")}`);
        const candidates: OsmBatchCandidate[] = (rows as StoredReport[]).map((r) => {
          const d = r.data;
          let overpassId = typeof d.overpassId === "number" ? d.overpassId : undefined;
          // A cypher fix on a box we added from a report, whose create has
          // since been uploaded and its node id recorded: target that node.
          if (overpassId === undefined && typeof d.postboxId === "string" && d.postboxId.startsWith("manual_")) {
            const origin = store.get(d.postboxId.slice("manual_".length));
            if (typeof origin?.data.osmNodeId === "number") overpassId = origin.data.osmNodeId;
          }
          return {
            reportId: r.id,
            type: d.type,
            reviewedAtMs: toMs(d.reviewedAt) ?? 0,
            ...(typeof d.lat === "number" ? { lat: d.lat } : {}),
            ...(typeof d.lng === "number" ? { lng: d.lng } : {}),
            ...(typeof d.postboxId === "string" ? { postboxId: d.postboxId } : {}),
            ...(overpassId !== undefined ? { overpassId } : {}),
            finalMonarch: typeof d.finalMonarch === "string" ? d.finalMonarch : null,
            ...(typeof d.finalReference === "string" ? { finalReference: d.finalReference } : {}),
          };
        });
        const nodeIds = [...new Set(candidates.filter((c) => c.type === "wrong_cypher" && c.overpassId !== undefined).map((c) => c.overpassId as number))];
        const lookups = await mapWithConcurrency(nodeIds, OSM_FETCH_CONCURRENCY, (id) => fetchOsmNodeResult(id));
        const fresh = new Map<number, OsmNodeResult>(nodeIds.map((id, i) => [id, lookups[i]]));
        const plan = planOsmBatch(candidates, fresh);
        const osc = buildOsmChangeBatch(plan.inputs);
        const stamp = new Date().toISOString().replace(/[:.]/g, "-");
        let storagePath: string | null = null;
        if (plan.inputs.length > 0) {
          try {
            storagePath = `osm_changesets/batch_${stamp}.osc`;
            await bucket.file(storagePath).save(osc, { contentType: "application/xml" });
          } catch (e) {
            console.error("[review-dashboard] batch .osc upload failed (download still works):", (e as Error).message);
            storagePath = null;
          }
        }
        const out: OsmBatchDto = {
          osc,
          filename: `postbox-game-${stamp}.osc`,
          storagePath,
          nodeCount: plan.inputs.length,
          entries: plan.entries,
          suggestedComment: suggestedChangesetComment(plan),
        };
        sendJson(res, 200, out);
      },
    },
    {
      method: "POST",
      pattern: /^\/api\/osm\/mark-uploaded$/,
      handler: async ({ req, res }) => {
        await assertReviewer();
        const body = await readJsonBody(req);
        if (!isObject(body)) throw new HttpError(400, "invalid-argument", "Expected a JSON object");
        const ids = requireIds(body.reportIds, MAX_OSM_BATCH);
        const bad = ids.filter((id) => {
          const r = store.get(id);
          return !r || r.data.status !== "accepted";
        });
        if (bad.length > 0) throw new HttpError(400, "invalid-argument", `Not accepted: ${bad.join(", ")}`);
        const cs = body.changesetId;
        if (cs !== undefined && cs !== null && !(typeof cs === "number" && Number.isInteger(cs) && cs > 0)) {
          throw new HttpError(400, "invalid-argument", "changesetId must be a positive integer");
        }
        const created: Record<string, number> = {};
        if (body.createdNodeIds !== undefined) {
          if (!isObject(body.createdNodeIds)) throw new HttpError(400, "invalid-argument", "createdNodeIds must be an object");
          for (const [k, v] of Object.entries(body.createdNodeIds)) {
            if (!ids.includes(k)) throw new HttpError(400, "invalid-argument", `createdNodeIds has unknown report ${k}`);
            if (!(typeof v === "number" && Number.isInteger(v) && v > 0)) throw new HttpError(400, "invalid-argument", `Bad node id for ${k}`);
            created[k] = v;
          }
        }
        await markOsmUploaded(db, reviewerUid, ids, typeof cs === "number" ? cs : null, created, admin.firestore.Timestamp.now());
        await Promise.all(ids.map((id) => store.refresh(id)));
        logWrite(`marked ${ids.length} report(s) uploaded to OSM${typeof cs === "number" ? ` in changeset ${cs}` : ""} by ${reviewerUid}`);
        sendJson(res, 200, { ok: true });
      },
    },
    {
      method: "POST",
      pattern: /^\/api\/osm\/mark-skipped$/,
      handler: async ({ req, res }) => {
        await assertReviewer();
        const body = await readJsonBody(req);
        if (!isObject(body)) throw new HttpError(400, "invalid-argument", "Expected a JSON object");
        const ids = requireIds(body.reportIds, MAX_OSM_BATCH);
        const reason = typeof body.reason === "string" ? body.reason.trim() : "";
        if (reason.length === 0 || reason.length > 200) throw new HttpError(400, "invalid-argument", "reason must be 1-200 characters");
        const bad = ids.filter((id) => store.get(id)?.data.status !== "accepted");
        if (bad.length > 0) throw new HttpError(400, "invalid-argument", `Not accepted: ${bad.join(", ")}`);
        await markOsmSkipped(db, reviewerUid, ids, reason, admin.firestore.Timestamp.now());
        await Promise.all(ids.map((id) => store.refresh(id)));
        logWrite(`marked ${ids.length} report(s) as needing no OSM upload by ${reviewerUid}: ${reason}`);
        sendJson(res, 200, { ok: true });
      },
    },
  ];

  // ── static files ─────────────────────────────────────────────────────────
  const distReady = fs.existsSync(`${opts.staticDir}/index.html`);

  function serveStatic(pathname: string, res: http.ServerResponse, headOnly: boolean): void {
    if (!distReady) {
      const msg = opts.devPort !== null
        ? `<p>Running with --dev: open the Vite dev server on port ${opts.devPort} instead.</p>`
        : "<p>The dashboard hasn't been built. Run <code>npm ci &amp;&amp; npm run build</code> in <code>admin_dashboard/</code>, then restart.</p>";
      res.writeHead(503, { "Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": PAGE_CSP, "X-Content-Type-Options": "nosniff" });
      res.end(`<!doctype html><title>Review dashboard</title>${msg}`);
      return;
    }
    const file = resolveStaticPath(opts.staticDir, pathname);
    if (!file || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
      res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
      res.end("Not found");
      return;
    }
    const isHtml = file.endsWith(".html");
    res.writeHead(200, {
      "Content-Type": contentTypeFor(file),
      "X-Content-Type-Options": "nosniff",
      "Cache-Control": isHtml ? "no-cache" : pathname.startsWith("/assets/") ? "public, max-age=31536000, immutable" : "no-cache",
      ...(isHtml ? { "Content-Security-Policy": PAGE_CSP, "X-Frame-Options": "DENY" } : {}),
    });
    if (headOnly) {
      res.end();
      return;
    }
    fs.createReadStream(file).pipe(res);
  }

  // ── request handling ─────────────────────────────────────────────────────
  /** The gate every /api request passes before routing (see _security.ts). */
  function refuseApiRequest(req: http.IncomingMessage, method: string): HttpError | null {
    // No CORS, ever: a preflight is answered with a refusal.
    if (method === "OPTIONS") return new HttpError(405, "method-not-allowed", "No CORS here");
    if (!isAllowedFetchSite(req.headers["sec-fetch-site"] as string | undefined)) {
      return new HttpError(403, "forbidden", "Cross-site requests are refused");
    }
    const token = req.headers[TOKEN_HEADER];
    if (!tokenMatches(Array.isArray(token) ? token[0] : token, opts.token)) {
      return new HttpError(401, "unauthenticated", "Missing or wrong dashboard token. Open the URL the server printed.");
    }
    if (method === "POST") {
      if (!isAllowedOrigin(req.headers.origin, origins)) return new HttpError(403, "forbidden", "Bad Origin");
      if (!isJsonContentType(req.headers["content-type"])) return new HttpError(415, "unsupported-media-type", "Send application/json");
    }
    return null;
  }

  async function handle(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    if (!isAllowedHost(req.headers.host, opts.port)) {
      res.writeHead(403, { "Content-Type": "text/plain; charset=utf-8" });
      res.end("Forbidden host");
      return;
    }
    const url = new URL(req.url ?? "/", `http://127.0.0.1:${opts.port}`);
    const method = req.method ?? "GET";

    if (url.pathname.startsWith("/api/")) {
      const refusal = refuseApiRequest(req, method);
      if (refusal) {
        sendError(res, refusal);
        return;
      }
      const match = matchRoute(routes, method, url.pathname);
      if (!match) {
        sendError(res, new HttpError(404, "not-found", "No such endpoint"));
        return;
      }
      try {
        await match.route.handler({ req, res, params: match.params, query: url.searchParams });
      } catch (e) {
        const he = toHttpError(e);
        if (he.status >= 500) console.error(`[review-dashboard] ${method} ${url.pathname} failed:`, e);
        if (!res.headersSent) sendError(res, he);
        else res.destroy();
      }
      return;
    }

    if (method !== "GET" && method !== "HEAD") {
      res.writeHead(405, { "Content-Type": "text/plain; charset=utf-8" });
      res.end("Method not allowed");
      return;
    }
    serveStatic(url.pathname, res, method === "HEAD");
  }

  const server = http.createServer((req, res) => {
    handle(req, res).catch((e) => {
      console.error("[review-dashboard] unhandled:", e);
      if (!res.headersSent) sendError(res, toHttpError(e));
      else res.destroy();
    });
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", (e: NodeJS.ErrnoException) => {
      reject(e.code === "EADDRINUSE" ? new StartupError(`Port ${opts.port} is already in use.`, "Pass --port <n> to use another.") : e);
    });
    server.listen(opts.port, "127.0.0.1", () => resolve());
  });

  return {
    reviewer,
    pointsOverrideActive: config.pointsOverride !== null,
    maintenanceMode: config.maintenanceMode,
    reportCount: store.all().length,
    close: () =>
      new Promise<void>((resolve) => {
        store.stop();
        server.close(() => resolve());
        server.closeAllConnections?.();
      }),
  };
}
