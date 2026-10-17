// Wire types shared by the reviewReport core (reports.ts), the local review
// dashboard server (scripts/review_dashboard/) and its React frontend
// (admin_dashboard/, via `import type`).
//
// MUST stay import-free and type-only (string unions, no enums, no values):
// the frontend's bundler erases these imports, so anything that needs a
// runtime value or a Node/firebase-admin type would break the web build.

export type ReportType = "missing_postbox" | "wrong_cypher";
export type ReportStatus = "pending" | "accepted" | "rejected";
export type OsmStatus = "not_started" | "changeset_generated" | "changeset_failed";

/** Body of POST /api/reports/:id/review (and the callable's data, minus reportId). */
export interface ReviewRequestDto {
  decision: "accept" | "reject";
  reviewNote?: string;
  /** A KNOWN_MONARCHS key, null for plain, or omitted to fall back to the reporter's suggestion. */
  finalMonarch?: string | null;
  /** Omitted falls back to the reporter's suggestion; "" explicitly sets none. */
  finalReference?: string;
}

export type ReviewReportResult =
  | { status: "rejected" }
  | {
      status: "accepted";
      osmEditUrl: string;
      osmChangesetPath: string | null;
      rescoredClaims: number;
      affectedUsers: number;
      /** Sum of every claimant's points change (0 for missing_postbox). */
      rescoreTotalDelta: number;
    };

// ── review dashboard API DTOs ───────────────────────────────────────────────
// Timestamps travel as epoch milliseconds (null when absent/unreadable).

export interface ApiErrorDto {
  error: { code: string; message: string };
}

export interface MonarchOptionDto {
  key: string;
  /** Live points value (Remote Config override applied). */
  points: number;
}

export interface SessionDto {
  reviewer: { uid: string; displayName: string | null };
  projectId: string;
  monarchs: MonarchOptionDto[];
  plainPoints: number;
  pointsOverrideActive: boolean;
  maintenanceMode: boolean;
  /** --ignore-maintenance was passed: writes allowed despite maintenance mode. */
  ignoreMaintenance: boolean;
  noteMax: number;
  referenceMax: number;
  rejectPresets: string[];
  storeReady: boolean;
}

export interface ReportSummaryDto {
  id: string;
  type: ReportType;
  status: ReportStatus;
  createdAtMs: number | null;
  reporterUid: string;
  reporterName: string | null;
  /** missing_postbox: the reported spot; wrong_cypher: the box's position once resolved. */
  lat: number | null;
  lng: number | null;
  postboxId: string | null;
  currentMonarch: string | null;
  /** false = the reporter chose "not sure" (suggestedMonarch then null). */
  hasSuggestedMonarch: boolean;
  /** A KNOWN_MONARCHS key, or null for plain (when hasSuggestedMonarch). */
  suggestedMonarch: string | null;
  suggestedReference: string | null;
  photoCount: number;
  hasNote: boolean;
  reviewedAtMs: number | null;
  reviewedBy: string | null;
  reviewedByName: string | null;
  reviewNote: string | null;
  finalMonarch: string | null;
  finalReference: string | null;
  osmStatus: OsmStatus | null;
  rescoredClaims: number | null;
  affectedUsers: number | null;
  rescoreTotalDelta: number | null;
  osmUploadedAtMs: number | null;
  osmSkippedAtMs: number | null;
}

export interface PhotoDto {
  index: number;
  exifLat: number | null;
  exifLng: number | null;
  /** Raw EXIF DateTimeOriginal ("YYYY:MM:DD HH:MM:SS", camera-local time). */
  takenAt: string | null;
  /** Metres from the report's anchor (reported spot or the box), when both are known. */
  distanceM: number | null;
  /** Hours between capture and report (approximate: EXIF has no time zone). */
  hoursBeforeReport: number | null;
}

export interface PostboxInfoDto {
  id: string;
  lat: number;
  lng: number;
  monarch: string | null;
  reference: string | null;
  county: string | null;
  overpassId: number | null;
  source: string | null;
  removedFromOsm: boolean;
  correctedBy: string | null;
  correctedAtMs: number | null;
}

export interface ReportDetailDto extends ReportSummaryDto {
  note: string | null;
  photos: PhotoDto[];
  accuracyMeters: number | null;
  overpassId: number | null;
  /** wrong_cypher: the box as stored now (null if it has been deleted). */
  postbox: PostboxInfoDto | null;
  osmEditUrl: string | null;
  osmChangesetPath: string | null;
  osmChangesetId: number | null;
  osmNodeId: number | null;
  osmSkipReason: string | null;
  /** Reviewed long enough ago that the retention sweep removed note + photos. */
  mediaPurged: boolean;
}

export type DuplicateSeverity = "high" | "medium" | "info";

export interface DuplicateFlagDto {
  severity: DuplicateSeverity;
  message: string;
  target?: { kind: "postbox" | "report" | "osm"; id: string };
}

export interface NearbyPostboxDto extends PostboxInfoDto {
  distanceM: number;
}

export interface NearbyReportDto {
  id: string;
  type: ReportType;
  status: ReportStatus;
  lat: number;
  lng: number;
  distanceM: number;
  createdAtMs: number | null;
}

export interface MapContextDto {
  anchor: { lat: number; lng: number; kind: "reported" | "postbox" } | null;
  accuracyMeters: number | null;
  radiusM: number;
  photos: PhotoDto[];
  postboxes: NearbyPostboxDto[];
  reports: NearbyReportDto[];
  flags: DuplicateFlagDto[];
}

export interface ReporterContextDto {
  uid: string;
  displayName: string | null;
  /** Account deleted: the report was anonymised. */
  deletedAccount: boolean;
  /** Auth metadata only, deliberately never email or phone. */
  account: { createdAtMs: number | null; lastSignInMs: number | null; providers: string[]; disabled: boolean } | null;
  stats: { lifetimePoints: number; uniquePostboxesClaimed: number; streak: number; lastClaimDate: string | null } | null;
  trustScore: number;
  trustScoreIsDefault: boolean;
  flags: {
    total: number;
    unreviewed: number;
    bySeverity: Record<string, number>;
    recent: Array<{ id: string; severity: string; reasons: string[]; createdAtMs: number | null; reviewed: boolean }>;
  };
  reports: {
    total: number;
    pending: number;
    accepted: number;
    rejected: number;
    /** accepted / (accepted + rejected), null before any decision. */
    acceptanceRate: number | null;
    recent: Array<{ id: string; type: ReportType; status: ReportStatus; createdAtMs: number | null }>;
  };
  /** wrong_cypher only: the reporter's claims on this box. */
  claimedThisBox: { count: number; lastDailyDate: string | null } | null;
}

export interface ReportContextDto {
  map: MapContextDto;
  reporter: ReporterContextDto;
}

export interface OsmNearbyNodeDto {
  id: number;
  lat: number;
  lon: number;
  tags: Record<string, string>;
  version: number | null;
  timestamp: string | null;
  user: string | null;
  lifecycle: "active" | "disused" | "was";
  distanceM: number;
  /** postbox/{id} that mirrors this node, when we have one. */
  firestoreId: string | null;
}

export interface OsmNearbyDto {
  nodes: OsmNearbyNodeDto[];
  fetchedAtMs: number;
  cached: boolean;
  /** Flags that only live OSM data can raise (e.g. a node we haven't imported). */
  flags: DuplicateFlagDto[];
}

export interface CypherImpactUserDto {
  uid: string;
  displayName: string | null;
  claims: number;
  delta: number;
  lifetimePointsBefore: number | null;
  lifetimePointsAfter: number | null;
}

export interface CypherImpactDto {
  postboxId: string;
  newMonarch: string | null;
  newPoints: number;
  totalClaims: number;
  claimsToRewrite: number;
  /** Users whose totals change (matches the accept's affectedUsers). */
  affectedUsers: number;
  totalDelta: number;
  deletedAccountClaims: number;
  /** Largest |delta| first, capped. */
  users: CypherImpactUserDto[];
  usersTruncated: boolean;
}

export interface BatchItemResultDto {
  reportId: string;
  ok: boolean;
  code?: string;
  message?: string;
}

export type OsmBatchEntryStatus =
  | "included"
  | "already_applied"
  | "node_missing"
  | "fetch_failed"
  | "conflict"
  | "no_target"
  | "merged_into_create";

export interface OsmBatchEntryDto {
  reportId: string;
  action: "create" | "modify" | null;
  /** OSM node id (negative placeholder for a create). */
  nodeId: number | null;
  status: OsmBatchEntryStatus;
  detail?: string;
}

export interface OsmBatchDto {
  osc: string;
  filename: string;
  storagePath: string | null;
  nodeCount: number;
  entries: OsmBatchEntryDto[];
  suggestedComment: string;
}
