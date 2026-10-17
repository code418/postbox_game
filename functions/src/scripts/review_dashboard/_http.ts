// Minimal HTTP plumbing for the review dashboard (node:http, no framework):
// a regex router, JSON responses, bounded JSON bodies, and error mapping.

import type { IncomingMessage, ServerResponse } from "http";
import { OverpassError } from "../../_overpass";
import { MAX_BODY_BYTES } from "./_security";

export class HttpError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) {
    super(message);
  }
}

/** HttpsError (thrown by performReview & co.) → its HTTP status;
 *  OverpassError → 502; everything else → 500. */
export function toHttpError(e: unknown): HttpError {
  if (e instanceof HttpError) return e;
  const o = e as { code?: unknown; message?: unknown; httpErrorCode?: { status?: unknown } };
  const message = typeof o?.message === "string" ? o.message : String(e);
  if (typeof o?.code === "string" && typeof o.httpErrorCode?.status === "number") {
    return new HttpError(o.httpErrorCode.status, o.code, message);
  }
  if (e instanceof OverpassError) return new HttpError(502, "bad-gateway", message);
  return new HttpError(500, "internal", message);
}

export const API_HEADERS: Record<string, string> = {
  "Cache-Control": "no-store",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
};

export function sendJson(res: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, { ...API_HEADERS, "Content-Type": "application/json; charset=utf-8", "Content-Length": Buffer.byteLength(payload) });
  res.end(payload);
}

export function sendError(res: ServerResponse, e: HttpError): void {
  sendJson(res, e.status, { error: { code: e.code, message: e.message } });
}

export function readJsonBody(req: IncomingMessage, maxBytes: number = MAX_BODY_BYTES): Promise<unknown> {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => {
      size += c.length;
      if (size > maxBytes) {
        reject(new HttpError(413, "payload-too-large", `Body over ${maxBytes} bytes`));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => {
      try {
        resolve(chunks.length === 0 ? {} : JSON.parse(Buffer.concat(chunks).toString("utf8")));
      } catch {
        reject(new HttpError(400, "invalid-argument", "Body is not valid JSON"));
      }
    });
    req.on("error", reject);
  });
}

export interface RouteContext {
  req: IncomingMessage;
  res: ServerResponse;
  params: string[];
  query: URLSearchParams;
}

export interface Route {
  method: "GET" | "POST";
  pattern: RegExp;
  handler: (ctx: RouteContext) => Promise<void>;
}

/** First route whose method + anchored pattern match; captures are URL-decoded. */
export function matchRoute(routes: ReadonlyArray<Route>, method: string, pathname: string): { route: Route; params: string[] } | null {
  for (const route of routes) {
    if (route.method !== method) continue;
    const m = route.pattern.exec(pathname);
    if (!m) continue;
    try {
      return { route, params: m.slice(1).map((p) => decodeURIComponent(p)) };
    } catch {
      return null;
    }
  }
  return null;
}

/** An id that is safe as a single Firestore path segment. */
export function requireId(raw: string | undefined, what = "id"): string {
  if (typeof raw !== "string" || raw.length === 0 || raw.length > 200 || raw.includes("/")) {
    throw new HttpError(400, "invalid-argument", `Invalid ${what}`);
  }
  return raw;
}

/** A non-empty array of ids, at most `max`. */
export function requireIds(raw: unknown, max: number): string[] {
  if (!Array.isArray(raw) || raw.length === 0 || raw.length > max) {
    throw new HttpError(400, "invalid-argument", `reportIds must be an array of 1-${max} ids`);
  }
  return [...new Set(raw.map((x) => requireId(typeof x === "string" ? x : undefined, "report id")))];
}
