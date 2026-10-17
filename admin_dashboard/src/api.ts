// Typed client for the local review server. Every request carries the
// per-launch token from the URL the server printed (#t=…), which is moved
// into sessionStorage and stripped from the address bar on load.

import type {
  BatchItemResultDto,
  CypherImpactDto,
  OsmBatchDto,
  OsmNearbyDto,
  ReportContextDto,
  ReportDetailDto,
  ReportSummaryDto,
  ReviewReportResult,
  ReviewRequestDto,
  SessionDto,
} from "../../functions/src/_reviewTypes";

const TOKEN_KEY = "postbox-review-token";
let token: string | null = null;

/** Reads the token from #t=… (then removes it from the URL) or sessionStorage. */
export function loadToken(): string | null {
  const m = /(?:^#|&)t=([^&]+)/.exec(window.location.hash);
  if (m) {
    token = decodeURIComponent(m[1]);
    try {
      sessionStorage.setItem(TOKEN_KEY, token);
    } catch {
      // Private mode: the in-memory copy still works for this tab.
    }
    window.history.replaceState(null, "", window.location.pathname + window.location.search);
    return token;
  }
  try {
    token = sessionStorage.getItem(TOKEN_KEY);
  } catch {
    token = null;
  }
  return token;
}

export class ApiError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) {
    super(message);
  }
}

async function raw(method: "GET" | "POST", path: string, body?: unknown): Promise<Response> {
  let res: Response;
  try {
    res = await fetch(path, {
      method,
      headers: { "X-Review-Token": token ?? "", ...(body !== undefined ? { "Content-Type": "application/json" } : {}) },
      body: body !== undefined ? JSON.stringify(body) : undefined,
      credentials: "same-origin",
    });
  } catch {
    throw new ApiError(0, "offline", "Can't reach the review server. Is it still running?");
  }
  if (!res.ok) {
    let code = "http";
    let message = `The server answered ${res.status}.`;
    try {
      const j = (await res.json()) as { error?: { code?: string; message?: string } };
      code = j.error?.code ?? code;
      message = j.error?.message ?? message;
    } catch {
      // Non-JSON error body: keep the generic message.
    }
    throw new ApiError(res.status, code, message);
  }
  return res;
}

async function json<T>(method: "GET" | "POST", path: string, body?: unknown): Promise<T> {
  return (await (await raw(method, path, body)).json()) as T;
}

export async function fetchBlob(path: string): Promise<Blob> {
  return (await raw("GET", path)).blob();
}

const r = (id: string) => `/api/reports/${encodeURIComponent(id)}`;

export interface HistoryParams {
  status: "accepted" | "rejected" | "all";
  type: "missing_postbox" | "wrong_cypher" | "all";
  before: number | null;
  limit?: number;
}

export const api = {
  session: () => json<SessionDto>("GET", "/api/session"),
  pending: () => json<{ reports: ReportSummaryDto[] }>("GET", "/api/reports?status=pending"),
  history: (p: HistoryParams) => {
    const q = new URLSearchParams({ status: p.status, type: p.type, limit: String(p.limit ?? 50) });
    if (p.before !== null) q.set("before", String(p.before));
    return json<{ reports: ReportSummaryDto[]; nextBefore: number | null }>("GET", `/api/reports/history?${q}`);
  },
  detail: (id: string) => json<ReportDetailDto>("GET", r(id)),
  context: (id: string) => json<ReportContextDto>("GET", `${r(id)}/context`),
  osmNearby: (id: string, radius = 150) => json<OsmNearbyDto>("GET", `${r(id)}/osm-nearby?radius=${radius}`),
  impact: (id: string, finalMonarch: string) => json<CypherImpactDto>("GET", `${r(id)}/impact?finalMonarch=${encodeURIComponent(finalMonarch)}`),
  review: (id: string, body: ReviewRequestDto) => json<ReviewReportResult>("POST", `${r(id)}/review`, body),
  batchReject: (reportIds: string[], reviewNote: string) =>
    json<{ results: BatchItemResultDto[] }>("POST", "/api/reports/batch-reject", { reportIds, ...(reviewNote ? { reviewNote } : {}) }),
  osmPending: () => json<{ reports: ReportSummaryDto[] }>("GET", "/api/osm/pending"),
  osmBatch: (reportIds: string[]) => json<OsmBatchDto>("POST", "/api/osm/batch", { reportIds }),
  markUploaded: (reportIds: string[], changesetId: number | null, createdNodeIds: Record<string, number>) =>
    json<{ ok: true }>("POST", "/api/osm/mark-uploaded", { reportIds, changesetId, createdNodeIds }),
  markSkipped: (reportIds: string[], reason: string) => json<{ ok: true }>("POST", "/api/osm/mark-skipped", { reportIds, reason }),
  photoPath: (id: string, index: number) => `${r(id)}/photos/${index}`,
  oscPath: (id: string) => `${r(id)}/osc`,
};

/** Saves text or a blob as a file download. */
export function saveFile(name: string, data: Blob | string, type = "application/xml"): void {
  const blob = typeof data === "string" ? new Blob([data], { type }) : data;
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}
