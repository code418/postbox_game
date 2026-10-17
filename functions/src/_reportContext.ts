// Review context for the local review dashboard: everything around a report
// that helps a reviewer decide (where the photos were taken, what is already
// mapped nearby, who the reporter is). Pure helpers first, then the two
// Firestore-backed builders. Reads only; never writes.

import type { firestore } from "firebase-admin";
import { DELETED_UID } from "./_accountDeletion";
import { DEFAULT_TRUST_SCORE } from "./_abuseSignals";
import { getLatLng } from "./_geo";
import { queryPostboxesNear } from "./_postboxQuery";
import { metresBetween } from "./_routePlanner";
import type {
  DuplicateFlagDto,
  MapContextDto,
  NearbyPostboxDto,
  NearbyReportDto,
  OsmNearbyNodeDto,
  PhotoDto,
  PostboxInfoDto,
  ReportStatus,
  ReportType,
  ReporterContextDto,
} from "./_reviewTypes";
import type { PostboxDoc, ReportDoc, ReportPhoto } from "./types";

type Firestore = firestore.Firestore;
type LatLng = { lat: number; lng: number };

/** Default radius for "what's around this report". */
export const CONTEXT_RADIUS_M = 150;
/** A stored box this close to a "missing" report is almost certainly the same box. */
export const DUPLICATE_HIGH_M = 10;
/** Within this, worth a second look. */
export const DUPLICATE_MEDIUM_M = 30;
const RECENT_LIMIT = 10;
const FLAG_QUERY_LIMIT = 200;

/** A report as held in the dashboard's in-memory store. */
export interface StoredReport {
  id: string;
  data: ReportDoc & Record<string, unknown>;
}

// ── pure helpers ────────────────────────────────────────────────────────────

/** Epoch ms from a Firestore Timestamp (or its serialised shapes), a Date or
 *  a number; null for anything else. */
export function toMs(v: unknown): number | null {
  if (v === null || v === undefined) return null;
  if (typeof v === "number") return Number.isFinite(v) ? v : null;
  if (v instanceof Date) return v.getTime();
  const o = v as { toMillis?: () => number; _seconds?: number; seconds?: number; _nanoseconds?: number; nanoseconds?: number };
  if (typeof o.toMillis === "function") return o.toMillis();
  const secs = o._seconds ?? o.seconds;
  if (typeof secs === "number") return secs * 1000 + Math.floor((o._nanoseconds ?? o.nanoseconds ?? 0) / 1e6);
  return null;
}

/** EXIF "YYYY:MM:DD HH:MM:SS" (or ISO) to epoch ms, read as UTC. EXIF carries
 *  no zone, so results are only good to about an hour. */
export function parseExifDateTime(raw: string | undefined | null): number | null {
  if (!raw) return null;
  const m = /^(\d{4})[:-](\d{2})[:-](\d{2})[ T](\d{2}):(\d{2}):(\d{2})/.exec(raw.trim());
  if (!m) return null;
  const [year, month, day, hh, mm, ss] = m.slice(1, 7).map(Number);
  const ms = Date.UTC(year, month - 1, day, hh, mm, ss);
  return Number.isFinite(ms) ? ms : null;
}

/** EXIF GPS, treating 0/0 ("Null Island", a common bogus default) as absent,
 *  like the in-app admin screen does. */
function exifPosition(p: ReportPhoto): LatLng | null {
  if (typeof p.exifLat !== "number" || typeof p.exifLng !== "number") return null;
  if (p.exifLat === 0 && p.exifLng === 0) return null;
  return { lat: p.exifLat, lng: p.exifLng };
}

export function photoDistances(photos: ReadonlyArray<ReportPhoto>, anchor: LatLng | null, createdAtMs: number | null): PhotoDto[] {
  return photos.map((p, index) => {
    const pos = exifPosition(p);
    const takenMs = parseExifDateTime(p.takenAt);
    return {
      index,
      exifLat: pos?.lat ?? null,
      exifLng: pos?.lng ?? null,
      takenAt: typeof p.takenAt === "string" ? p.takenAt : null,
      distanceM: pos && anchor ? metresBetween(anchor, pos) : null,
      hoursBeforeReport: takenMs !== null && createdAtMs !== null ? Math.round((createdAtMs - takenMs) / 360_000) / 10 : null,
    };
  });
}

export function postboxInfo(id: string, data: PostboxDoc & Record<string, unknown>, pos: LatLng): PostboxInfoDto {
  return {
    id,
    lat: pos.lat,
    lng: pos.lng,
    monarch: typeof data.monarch === "string" && data.monarch.length > 0 ? data.monarch : null,
    reference: typeof data.reference === "string" ? data.reference : null,
    county: typeof data.county === "string" ? data.county : null,
    overpassId: typeof data.overpass_id === "number" ? data.overpass_id : null,
    source: typeof data.source === "string" ? data.source : null,
    removedFromOsm: data.removedFromOsm === true,
    correctedBy: typeof data.correctedBy === "string" ? data.correctedBy : null,
    correctedAtMs: toMs(data.correctedAt),
  };
}

const SEVERITY_RANK: Record<DuplicateFlagDto["severity"], number> = { high: 0, medium: 1, info: 2 };

function cypherLabel(m: string | null): string {
  return m ?? "plain or unknown";
}

export interface DuplicateInputs {
  type: ReportType;
  postboxId: string | null;
  currentMonarch: string | null;
  hasSuggestedMonarch: boolean;
  suggestedMonarch: string | null;
  /** Stored boxes around the anchor (any order). */
  postboxes: ReadonlyArray<NearbyPostboxDto>;
  /** Other reports around the anchor (excluding this one). */
  reports: ReadonlyArray<NearbyReportDto>;
  /** Other wrong_cypher reports on the same box (excluding this one). */
  sameBoxReports: ReadonlyArray<{ id: string; status: ReportStatus }>;
}

/** Duplicate / sanity flags from stored data, most severe first. */
export function assessDuplicates(inp: DuplicateInputs): DuplicateFlagDto[] {
  const flags: DuplicateFlagDto[] = [];
  if (inp.type === "missing_postbox") {
    for (const pb of [...inp.postboxes].sort((a, b) => a.distanceM - b.distanceM)) {
      if (pb.distanceM > DUPLICATE_MEDIUM_M) break;
      if (pb.removedFromOsm) {
        flags.push({
          severity: "medium",
          message: `${pb.id}, ${pb.distanceM} m away, was pruned from OSM. It may be this box, so check before adding a new one.`,
          target: { kind: "postbox", id: pb.id },
        });
      } else {
        flags.push({
          severity: pb.distanceM <= DUPLICATE_HIGH_M ? "high" : "medium",
          message: `Already mapped: ${pb.id} is ${pb.distanceM} m away (${cypherLabel(pb.monarch)}).`,
          target: { kind: "postbox", id: pb.id },
        });
      }
    }
    for (const r of inp.reports) {
      if (r.type !== "missing_postbox" || r.distanceM > DUPLICATE_MEDIUM_M) continue;
      if (r.status === "pending") {
        flags.push({ severity: "medium", message: `Another pending report ${r.distanceM} m away.`, target: { kind: "report", id: r.id } });
      } else if (r.status === "rejected") {
        flags.push({ severity: "info", message: `A rejected report ${r.distanceM} m away.`, target: { kind: "report", id: r.id } });
      }
    }
  } else {
    const pending = inp.sameBoxReports.filter((r) => r.status === "pending");
    if (pending.length > 0) {
      flags.push({
        severity: "medium",
        message: `${pending.length} other pending report${pending.length === 1 ? "" : "s"} on this box.`,
        target: { kind: "report", id: pending[0].id },
      });
    }
    const accepted = inp.sameBoxReports.filter((r) => r.status === "accepted");
    if (accepted.length > 0) {
      flags.push({ severity: "info", message: "This box has been corrected before.", target: { kind: "report", id: accepted[0].id } });
    }
    if (inp.hasSuggestedMonarch && inp.suggestedMonarch === inp.currentMonarch) {
      flags.push({ severity: "info", message: `The suggestion matches what we already have (${cypherLabel(inp.currentMonarch)}).` });
    }
  }
  return flags.sort((a, b) => SEVERITY_RANK[a.severity] - SEVERITY_RANK[b.severity]);
}

/** Flags from live OSM data, most severe first. */
export function assessOsmNodes(
  inp: { type: ReportType; postboxId: string | null; hasSuggestedMonarch: boolean; suggestedMonarch: string | null },
  nodes: ReadonlyArray<OsmNearbyNodeDto>
): DuplicateFlagDto[] {
  const flags: DuplicateFlagDto[] = [];
  if (inp.type === "missing_postbox") {
    for (const n of nodes) {
      if (n.lifecycle !== "active" || n.firestoreId !== null || n.distanceM > DUPLICATE_MEDIUM_M) continue;
      flags.push({
        severity: n.distanceM <= DUPLICATE_HIGH_M ? "high" : "medium",
        message: `OSM node ${n.id}, ${n.distanceM} m away, isn't in our database yet. The next import adds it, so accepting would duplicate it.`,
        target: { kind: "osm", id: String(n.id) },
      });
    }
  } else {
    const own = nodes.find((n) => n.firestoreId !== null && n.firestoreId === inp.postboxId);
    if (own && inp.hasSuggestedMonarch) {
      const osmCypher = own.tags.royal_cypher ?? null;
      if (osmCypher === inp.suggestedMonarch) {
        flags.push({
          severity: "info",
          message: `OSM already tags this box ${cypherLabel(osmCypher)}, so no OSM edit is needed.`,
          target: { kind: "osm", id: String(own.id) },
        });
      }
    }
    if (own && own.lifecycle !== "active") {
      flags.push({ severity: "medium", message: `OSM marks this box as ${own.lifecycle}.`, target: { kind: "osm", id: String(own.id) } });
    }
  }
  return flags.sort((a, b) => SEVERITY_RANK[a.severity] - SEVERITY_RANK[b.severity]);
}

export function summariseReporterHistory(reports: ReadonlyArray<StoredReport>): ReporterContextDto["reports"] {
  let pending = 0;
  let accepted = 0;
  let rejected = 0;
  for (const r of reports) {
    if (r.data.status === "pending") pending++;
    else if (r.data.status === "accepted") accepted++;
    else if (r.data.status === "rejected") rejected++;
  }
  const recent = [...reports]
    .sort((a, b) => (toMs(b.data.createdAt) ?? 0) - (toMs(a.data.createdAt) ?? 0))
    .slice(0, RECENT_LIMIT)
    .map((r) => ({ id: r.id, type: r.data.type, status: r.data.status, createdAtMs: toMs(r.data.createdAt) }));
  return {
    total: reports.length,
    pending,
    accepted,
    rejected,
    acceptanceRate: accepted + rejected > 0 ? accepted / (accepted + rejected) : null,
    recent,
  };
}

/** The subset of firebase-admin's UserRecord the dashboard reads. */
export interface UserRecordLike {
  disabled?: boolean;
  metadata?: { creationTime?: string; lastSignInTime?: string };
  providerData?: ReadonlyArray<{ providerId?: string }>;
}

/** Account metadata for the reporter panel. Deliberately no email/phone/name:
 *  the reviewer needs account age and sign-in method, not contact details. */
export function accountSummary(user: UserRecordLike): NonNullable<ReporterContextDto["account"]> {
  const ms = (s?: string) => {
    const t = s ? Date.parse(s) : NaN;
    return Number.isFinite(t) ? t : null;
  };
  return {
    createdAtMs: ms(user.metadata?.creationTime),
    lastSignInMs: ms(user.metadata?.lastSignInTime),
    providers: (user.providerData ?? []).map((p) => p.providerId).filter((p): p is string => typeof p === "string"),
    disabled: user.disabled === true,
  };
}

/** Where a report sits: the reported spot, or (wrong_cypher) its box. */
export function reportPosition(r: StoredReport, boxPositions: ReadonlyMap<string, LatLng>): LatLng | null {
  if (r.data.type === "missing_postbox") {
    return typeof r.data.lat === "number" && typeof r.data.lng === "number" ? { lat: r.data.lat, lng: r.data.lng } : null;
  }
  return typeof r.data.postboxId === "string" ? boxPositions.get(r.data.postboxId) ?? null : null;
}

// ── Firestore-backed builders ───────────────────────────────────────────────

export async function buildMapContext(
  db: Firestore,
  report: StoredReport,
  allReports: ReadonlyArray<StoredReport>,
  boxPositions: Map<string, LatLng>,
  radiusM: number = CONTEXT_RADIUS_M
): Promise<MapContextDto> {
  const d = report.data;
  let anchor: MapContextDto["anchor"] = null;
  if (d.type === "missing_postbox") {
    const pos = reportPosition(report, boxPositions);
    if (pos) anchor = { ...pos, kind: "reported" };
  } else if (typeof d.postboxId === "string") {
    const snap = await db.collection("postbox").doc(d.postboxId).get();
    const pos = snap.exists ? getLatLng((snap.data() as PostboxDoc).geopoint) : null;
    if (pos) {
      boxPositions.set(d.postboxId, pos);
      anchor = { ...pos, kind: "postbox" };
    }
  }

  const createdAtMs = toMs(d.createdAt);
  const photos = photoDistances(Array.isArray(d.photos) ? d.photos : [], anchor, createdAtMs);

  let postboxes: NearbyPostboxDto[] = [];
  if (anchor) {
    const near = await queryPostboxesNear(db, anchor.lat, anchor.lng, radiusM);
    for (const pb of near) boxPositions.set(pb.id, { lat: pb.lat, lng: pb.lng });
    postboxes = near
      .map((pb) => ({ ...postboxInfo(pb.id, pb.data as PostboxDoc & Record<string, unknown>, pb), distanceM: pb.distanceM }))
      .sort((a, b) => a.distanceM - b.distanceM);
  }

  const reports: NearbyReportDto[] = [];
  if (anchor) {
    for (const r of allReports) {
      if (r.id === report.id) continue;
      const pos = reportPosition(r, boxPositions);
      if (!pos) continue;
      const distanceM = metresBetween(anchor, pos);
      if (distanceM > radiusM) continue;
      reports.push({ id: r.id, type: r.data.type, status: r.data.status, lat: pos.lat, lng: pos.lng, distanceM, createdAtMs: toMs(r.data.createdAt) });
    }
    reports.sort((a, b) => a.distanceM - b.distanceM);
  }

  const sameBoxReports = d.type === "wrong_cypher" && typeof d.postboxId === "string"
    ? allReports.filter((r) => r.id !== report.id && r.data.type === "wrong_cypher" && r.data.postboxId === d.postboxId)
      .map((r) => ({ id: r.id, status: r.data.status }))
    : [];

  return {
    anchor,
    accuracyMeters: typeof d.accuracyMeters === "number" ? d.accuracyMeters : null,
    radiusM,
    photos,
    postboxes,
    reports,
    flags: assessDuplicates({
      type: d.type,
      postboxId: typeof d.postboxId === "string" ? d.postboxId : null,
      currentMonarch: typeof d.currentMonarch === "string" ? d.currentMonarch : null,
      hasSuggestedMonarch: "suggestedMonarch" in d,
      suggestedMonarch: typeof d.suggestedMonarch === "string" ? d.suggestedMonarch : null,
      postboxes,
      reports,
      sameBoxReports,
    }),
  };
}

export interface AuthLike {
  getUser(uid: string): Promise<UserRecordLike>;
}

export async function buildReporterContext(
  db: Firestore,
  auth: AuthLike,
  uid: string,
  allReports: ReadonlyArray<StoredReport>,
  postboxKey: string | null
): Promise<ReporterContextDto> {
  const reports = summariseReporterHistory(allReports.filter((r) => r.data.reporterUid === uid));
  if (uid === DELETED_UID) {
    return {
      uid,
      displayName: null,
      deletedAccount: true,
      account: null,
      stats: null,
      trustScore: DEFAULT_TRUST_SCORE,
      trustScoreIsDefault: true,
      flags: { total: 0, unreviewed: 0, bySeverity: {}, recent: [] },
      reports,
      claimedThisBox: null,
    };
  }

  const [userSnap, trustSnap, flagSnap, account, claimSnap] = await Promise.all([
    db.collection("users").doc(uid).get(),
    db.collection("trustScores").doc(uid).get(),
    // Single-field equality (no composite index); sorted in memory below.
    db.collection("moderationFlags").where("uid", "==", uid).limit(FLAG_QUERY_LIMIT).get(),
    auth.getUser(uid).then(accountSummary, () => null),
    postboxKey
      ? db.collection("claims").where("postboxes", "==", `/postbox/${postboxKey}`).where("userid", "==", uid).get()
      : Promise.resolve(null),
  ]);

  const u = userSnap.exists ? (userSnap.data() as Record<string, unknown>) : null;
  const num = (v: unknown) => (typeof v === "number" ? v : 0);
  const score = trustSnap.exists ? (trustSnap.data() as { score?: unknown }).score : undefined;

  const bySeverity: Record<string, number> = {};
  let unreviewed = 0;
  const flagRows = flagSnap.docs.map((doc) => {
    const f = doc.data() as Record<string, unknown>;
    const severity = typeof f.severity === "string" ? f.severity : "unknown";
    bySeverity[severity] = (bySeverity[severity] ?? 0) + 1;
    if (f.reviewed !== true) unreviewed++;
    return {
      id: doc.id,
      severity,
      reasons: Array.isArray(f.reasons) ? f.reasons.filter((x): x is string => typeof x === "string") : [],
      createdAtMs: toMs(f.createdAt),
      reviewed: f.reviewed === true,
    };
  });
  flagRows.sort((a, b) => (b.createdAtMs ?? 0) - (a.createdAtMs ?? 0));

  let claimedThisBox: ReporterContextDto["claimedThisBox"] = null;
  if (claimSnap) {
    const dates = claimSnap.docs.map((c) => c.data().dailyDate).filter((x): x is string => typeof x === "string").sort();
    claimedThisBox = { count: claimSnap.size, lastDailyDate: dates.length > 0 ? dates[dates.length - 1] : null };
  }

  return {
    uid,
    displayName: typeof u?.displayName === "string" ? u.displayName : null,
    deletedAccount: false,
    account,
    stats: u
      ? {
          lifetimePoints: num(u.lifetimePoints),
          uniquePostboxesClaimed: num(u.uniquePostboxesClaimed),
          streak: num(u.streak),
          lastClaimDate: typeof u.lastClaimDate === "string" ? u.lastClaimDate : null,
        }
      : null,
    trustScore: typeof score === "number" ? score : DEFAULT_TRUST_SCORE,
    trustScoreIsDefault: typeof score !== "number",
    flags: { total: flagRows.length, unreviewed, bySeverity, recent: flagRows.slice(0, RECENT_LIMIT) },
    reports,
    claimedThisBox,
  };
}
