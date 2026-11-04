// Pure mappers from stored report docs to the dashboard's wire DTOs.

import { toMs, postboxInfo, type StoredReport } from "../../_reportContext";
import { getLatLng } from "../../_geo";
import type { OsmStatus, ReportDetailDto, ReportSummaryDto } from "../../_reviewTypes";
import type { PostboxDoc } from "../../types";

type LatLng = { lat: number; lng: number };

const str = (v: unknown): string | null => (typeof v === "string" ? v : null);
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);

export function toSummary(
  r: StoredReport,
  names: ReadonlyMap<string, string | null>,
  boxPositions: ReadonlyMap<string, LatLng>
): ReportSummaryDto {
  const d = r.data;
  const postboxId = str(d.postboxId);
  const pos = d.type === "missing_postbox"
    ? (num(d.lat) !== null && num(d.lng) !== null ? { lat: d.lat as number, lng: d.lng as number } : null)
    : (postboxId ? boxPositions.get(postboxId) ?? null : null);
  const hasSuggestedMonarch = "suggestedMonarch" in d && d.suggestedMonarch !== undefined;
  const reviewedBy = str(d.reviewedBy);
  const osmStatus = str(d.osmStatus);
  return {
    id: r.id,
    type: d.type,
    status: d.status,
    createdAtMs: toMs(d.createdAt),
    reporterUid: d.reporterUid,
    reporterName: names.get(d.reporterUid) ?? null,
    lat: pos?.lat ?? null,
    lng: pos?.lng ?? null,
    postboxId,
    currentMonarch: str(d.currentMonarch),
    hasSuggestedMonarch,
    suggestedMonarch: hasSuggestedMonarch ? str(d.suggestedMonarch) : null,
    suggestedReference: str(d.suggestedReference),
    photoCount: Array.isArray(d.photos) ? d.photos.length : 0,
    hasNote: typeof d.note === "string" && d.note.length > 0,
    reviewedAtMs: toMs(d.reviewedAt),
    reviewedBy,
    reviewedByName: reviewedBy ? names.get(reviewedBy) ?? null : null,
    reviewNote: str(d.reviewNote),
    finalMonarch: str(d.finalMonarch),
    finalReference: str(d.finalReference),
    osmStatus: osmStatus === "not_started" || osmStatus === "changeset_generated" || osmStatus === "changeset_failed" ? (osmStatus as OsmStatus) : null,
    rescoredClaims: num(d.rescoredClaims),
    affectedUsers: num(d.affectedUsers),
    rescoreTotalDelta: num(d.rescoreTotalDelta),
    osmUploadedAtMs: toMs(d.osmUploadedAt),
    osmSkippedAtMs: toMs(d.osmSkippedAt),
  };
}

export function toDetail(
  r: StoredReport,
  names: ReadonlyMap<string, string | null>,
  boxPositions: ReadonlyMap<string, LatLng>,
  postbox: { id: string; data: PostboxDoc & Record<string, unknown> } | null
): ReportDetailDto {
  const d = r.data;
  const photos = Array.isArray(d.photos) ? d.photos : [];
  const boxPos = postbox ? getLatLng(postbox.data.geopoint) : null;
  return {
    ...toSummary(r, names, boxPositions),
    note: str(d.note),
    // Distances/EXIF analysis come with the context call; here, metadata only.
    photos: photos.map((p, index) => ({
      index,
      exifLat: num(p.exifLat),
      exifLng: num(p.exifLng),
      takenAt: str(p.takenAt),
      distanceM: null,
      hoursBeforeReport: null,
    })),
    accuracyMeters: num(d.accuracyMeters),
    overpassId: num(d.overpassId),
    postbox: postbox && boxPos ? postboxInfo(postbox.id, postbox.data, boxPos) : null,
    osmEditUrl: str(d.osmEditUrl),
    osmChangesetPath: str(d.osmChangesetPath),
    osmChangesetId: num(d.osmChangesetId),
    osmNodeId: num(d.osmNodeId),
    osmSkipReason: str(d.osmSkipReason),
    // The retention sweep deletes the photos field outright 30 days after
    // review; submitReport always writes one (possibly []).
    mediaPurged: d.status !== "pending" && !Array.isArray(d.photos),
  };
}

/** Pending queue order: oldest first (first in, first reviewed). */
export function pendingOrder(a: StoredReport, b: StoredReport): number {
  return (toMs(a.data.createdAt) ?? 0) - (toMs(b.data.createdAt) ?? 0) || a.id.localeCompare(b.id);
}

/** History order: most recently reviewed first. */
export function historyOrder(a: StoredReport, b: StoredReport): number {
  return (toMs(b.data.reviewedAt) ?? 0) - (toMs(a.data.reviewedAt) ?? 0) || a.id.localeCompare(b.id);
}

export interface HistoryQuery {
  status: "accepted" | "rejected" | "all";
  type: "missing_postbox" | "wrong_cypher" | "all";
  /** Only reports reviewed strictly before this (epoch ms): the paging cursor. */
  beforeMs: number | null;
  limit: number;
}

export function selectHistory(all: ReadonlyArray<StoredReport>, q: HistoryQuery): { reports: StoredReport[]; nextBefore: number | null } {
  const rows = all
    .filter((r) => r.data.status !== "pending")
    .filter((r) => q.status === "all" || r.data.status === q.status)
    .filter((r) => q.type === "all" || r.data.type === q.type)
    .filter((r) => q.beforeMs === null || (toMs(r.data.reviewedAt) ?? 0) < q.beforeMs)
    .sort(historyOrder);
  const page = rows.slice(0, q.limit);
  const last = page[page.length - 1];
  return { reports: page, nextBefore: rows.length > page.length && last ? toMs(last.data.reviewedAt) : null };
}

/** Accepted reports whose OSM follow-up hasn't been uploaded or skipped. */
export function isOsmPending(r: StoredReport): boolean {
  return r.data.status === "accepted" && r.data.osmUploadedAt === undefined && r.data.osmSkippedAt === undefined;
}
