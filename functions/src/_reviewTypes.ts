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
