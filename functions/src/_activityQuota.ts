// Pure per-user daily budgets for workout claims (activityQuotas/{uid}).
//
// One server-only doc per user: {date, sessions, routeMetres, claims, seen}.
//   - sessions / routeMetres: charged by matchActivityRoute per NEW route.
//   - claims: charged by claimActivityPostbox per claim attempt.
//   - seen: {sessionFp: {d: routeDigest, at}} — a route already matched with
//     an identical digest is re-matched FREE, so app reopens, retries and the
//     auto-check never burn budget. A changed digest (the fitness app rewrote
//     the record) is charged again. Pruned after SEEN_TTL_MS and capped.
// Counters reset on the London-day rollover; `seen` survives it (a run near
// midnight re-opened next morning is still free).

export interface ActivityQuotaState {
  date: string;
  sessions: number;
  routeMetres: number;
  claims: number;
  seen: Record<string, { d: string; at: number }>;
}

export const SEEN_TTL_MS = 48 * 60 * 60 * 1000;
export const MAX_SEEN_ENTRIES = 100;

function count(x: unknown): number {
  return typeof x === "number" && Number.isFinite(x) && x > 0 ? x : 0;
}

/** Normalise a possibly-junk stored doc: counters only carry over on the same
 *  day; stale or malformed `seen` entries are dropped. */
export function normaliseQuota(raw: unknown, today: string, nowMs: number): ActivityQuotaState {
  const r = (typeof raw === "object" && raw !== null ? raw : {}) as Record<string, unknown>;
  const sameDay = r.date === today;
  const seen: ActivityQuotaState["seen"] = {};
  const rawSeen = (typeof r.seen === "object" && r.seen !== null ? r.seen : {}) as Record<string, unknown>;
  const entries = Object.entries(rawSeen)
    .filter(([, v]) => {
      const e = v as { d?: unknown; at?: unknown } | null;
      return e !== null && e !== undefined && typeof e.d === "string" && typeof e.at === "number" &&
        Number.isFinite(e.at) && nowMs - e.at <= SEEN_TTL_MS;
    })
    .sort((a, b) => (b[1] as { at: number }).at - (a[1] as { at: number }).at)
    .slice(0, MAX_SEEN_ENTRIES);
  for (const [k, v] of entries) seen[k] = v as { d: string; at: number };
  return {
    date: today,
    sessions: sameDay ? count(r.sessions) : 0,
    routeMetres: sameDay ? count(r.routeMetres) : 0,
    claims: sameDay ? count(r.claims) : 0,
    seen,
  };
}

/** Decide whether a route match may run, and the doc to write.
 *  `charged` is false for a free re-match of an unchanged route. */
export function nextMatchQuota(
  raw: unknown,
  today: string,
  nowMs: number,
  req: { sessionFp: string; digest: string; lengthM: number },
  limits: { maxSessions: number; maxRouteM: number },
): { allowed: boolean; charged: boolean; state: ActivityQuotaState } {
  const s = normaliseQuota(raw, today, nowMs);
  if (s.seen[req.sessionFp]?.d === req.digest) {
    return { allowed: true, charged: false, state: s };
  }
  const lengthM = Math.max(0, Math.round(req.lengthM));
  if (s.sessions + 1 > limits.maxSessions || s.routeMetres + lengthM > limits.maxRouteM) {
    return { allowed: false, charged: false, state: s };
  }
  const seen = { ...s.seen, [req.sessionFp]: { d: req.digest, at: nowMs } };
  const trimmed = Object.fromEntries(
    Object.entries(seen).sort((a, b) => b[1].at - a[1].at).slice(0, MAX_SEEN_ENTRIES),
  );
  return {
    allowed: true,
    charged: true,
    state: { ...s, sessions: s.sessions + 1, routeMetres: s.routeMetres + lengthM, seen: trimmed },
  };
}

/** Decide whether one more workout claim may run today. */
export function nextClaimQuota(
  raw: unknown,
  today: string,
  nowMs: number,
  maxClaims: number,
): { allowed: boolean; state: ActivityQuotaState } {
  const s = normaliseQuota(raw, today, nowMs);
  if (s.claims + 1 > maxClaims) return { allowed: false, state: s };
  return { allowed: true, state: { ...s, claims: s.claims + 1 } };
}
