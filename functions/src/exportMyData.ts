// exportMyData — GDPR Art. 15 (access) / Art. 20 (portability) self-serve export.
//
// Returns a single JSON bundle of everything stored about the calling user,
// mirroring the authoritative per-user store list in _accountDeletion.ts (the
// erasure and access surfaces must never disagree about what exists):
// users/{uid} + countyStats, claims, reports, moderationFlags (anti-abuse
// profiling records are access-subject data too), fcmTokens, reportQuotas,
// offlineFlushQuotas, trustScores, leaderboard entries, and the Firebase Auth
// record (email lives only in Auth). The client offers it as
// Settings → "Download my data".

import "./adminInit";
import { monitorAppCheck } from "./_appCheck";
import * as admin from "firebase-admin";
import * as functions from "firebase-functions";

/** Newest-first cap on exported claims: ~300 B/doc keeps the worst case ~6 MB,
 *  under the 10 MB callable response limit. `claimsTruncated` flags the cut. */
export const EXPORT_CLAIMS_CAP = 20000;

/** Recursively convert Firestore types to portable JSON: Timestamp → ISO-8601
 *  string, GeoPoint → {lat, lng}. Everything else passes through. */
export function serialiseForExport(v: unknown): unknown {
  if (v === null || v === undefined) return null;
  if (v instanceof admin.firestore.Timestamp) return v.toDate().toISOString();
  if (v instanceof admin.firestore.GeoPoint) return { lat: v.latitude, lng: v.longitude };
  if (Array.isArray(v)) return v.map(serialiseForExport);
  if (typeof v === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, val] of Object.entries(v)) out[k] = serialiseForExport(val);
    return out;
  }
  return v;
}

export interface ExportParts {
  uid: string;
  generatedAtIso: string;
  account: Record<string, unknown> | null;
  profile: Record<string, unknown> | null;
  countyStats: Array<Record<string, unknown>>;
  claims: Array<Record<string, unknown>>;
  claimsTruncated: boolean;
  reports: Array<Record<string, unknown>>;
  moderationFlags: Array<Record<string, unknown>>;
  trustScore: Record<string, unknown> | null;
  reportQuota: Record<string, unknown> | null;
  offlineFlushQuota: Record<string, unknown> | null;
  fcmTokens: Record<string, unknown> | null;
  leaderboards: Array<{ board: string; entry: Record<string, unknown> }>;
}

/** Assemble the versioned response bundle (all values run through
 *  serialiseForExport). Pure — exported for unit testing. */
export function buildExportBundle(parts: ExportParts): Record<string, unknown> {
  return {
    exportVersion: 1,
    generatedAt: parts.generatedAtIso,
    uid: parts.uid,
    account: serialiseForExport(parts.account),
    profile: serialiseForExport(parts.profile),
    countyStats: serialiseForExport(parts.countyStats),
    claims: serialiseForExport(parts.claims),
    claimsTruncated: parts.claimsTruncated,
    reports: serialiseForExport(parts.reports),
    moderationFlags: serialiseForExport(parts.moderationFlags),
    trustScore: serialiseForExport(parts.trustScore),
    reportQuota: serialiseForExport(parts.reportQuota),
    offlineFlushQuota: serialiseForExport(parts.offlineFlushQuota),
    fcmTokens: serialiseForExport(parts.fcmTokens),
    leaderboards: serialiseForExport(parts.leaderboards),
    notes: {
      photos:
        "Files referenced by reports[].photos[].storagePath are available on request " +
        "(they are your uploaded report photos).",
      moderationFlags:
        "Internal anti-abuse anomaly records about your claims; they have no effect on " +
        "your account while the detector runs in shadow mode.",
      retention:
        "Claim location/device metadata is removed after 90 days, report photos and notes " +
        "30 days after review, and moderation records after 180 days.",
    },
  };
}

export const exportMyData = functions.https.onCall(async (request) => {
  monitorAppCheck(request, "exportMyData");
  const uid = request.auth?.uid;
  if (!uid) {
    throw new functions.https.HttpsError("unauthenticated", "Must be signed in to export your data");
  }

  const db = admin.firestore();
  const withId = (d: admin.firestore.QueryDocumentSnapshot | admin.firestore.DocumentSnapshot) =>
    ({ id: d.id, ...(d.data() ?? {}) }) as Record<string, unknown>;

  const [
    userSnap,
    countySnap,
    claimsSnap,
    reportsSnap,
    flagsSnap,
    fcmSnap,
    quotaSnap,
    offlineQuotaSnap,
    trustSnap,
    authUser,
  ] = await Promise.all([
    db.collection("users").doc(uid).get(),
    db.collection("users").doc(uid).collection("countyStats").get(),
    // No orderBy: userid-equality alone is served by the single-field index;
    // sorting/capping happens in memory to avoid a new composite index.
    db.collection("claims").where("userid", "==", uid).get(),
    db.collection("reports").where("reporterUid", "==", uid).get(),
    db.collection("moderationFlags").where("uid", "==", uid).get(),
    db.collection("fcmTokens").doc(uid).get(),
    db.collection("reportQuotas").doc(uid).get(),
    db.collection("offlineFlushQuotas").doc(uid).get(),
    db.collection("trustScores").doc(uid).get(),
    admin.auth().getUser(uid).catch(() => null),
  ]);

  const claims = claimsSnap.docs
    .map(withId)
    .sort((a, b) => {
      const ta = (a.timestamp as admin.firestore.Timestamp | undefined)?.toMillis?.() ?? 0;
      const tb = (b.timestamp as admin.firestore.Timestamp | undefined)?.toMillis?.() ?? 0;
      return tb - ta; // newest first
    });
  const claimsTruncated = claims.length > EXPORT_CLAIMS_CAP;

  const countySlugs = countySnap.docs.map((d) => d.id);
  const boardRefs = [
    ...["daily", "weekly", "monthly", "lifetime"].map((p) => ({
      board: p,
      ref: db.collection("leaderboards").doc(p),
    })),
    ...countySlugs.map((slug) => ({
      board: `lifetime_by_county/${slug}`,
      ref: db.collection("leaderboards").doc("lifetime_by_county").collection("counties").doc(slug),
    })),
  ];
  const boardSnaps = await Promise.all(boardRefs.map((b) => b.ref.get()));
  const leaderboards: Array<{ board: string; entry: Record<string, unknown> }> = [];
  boardSnaps.forEach((snap, i) => {
    const entries = (snap.data()?.entries ?? []) as Array<Record<string, unknown>>;
    for (const e of entries) {
      if (e.uid === uid) leaderboards.push({ board: boardRefs[i].board, entry: e });
    }
  });

  return buildExportBundle({
    uid,
    generatedAtIso: new Date().toISOString(),
    account: authUser
      ? {
          email: authUser.email ?? null,
          displayName: authUser.displayName ?? null,
          createdAt: authUser.metadata.creationTime ?? null,
          providers: authUser.providerData.map((p) => p.providerId),
        }
      : null,
    profile: userSnap.exists ? withId(userSnap) : null,
    countyStats: countySnap.docs.map(withId),
    claims: claims.slice(0, EXPORT_CLAIMS_CAP),
    claimsTruncated,
    reports: reportsSnap.docs.map(withId),
    moderationFlags: flagsSnap.docs.map(withId),
    trustScore: trustSnap.exists ? withId(trustSnap) : null,
    reportQuota: quotaSnap.exists ? withId(quotaSnap) : null,
    offlineFlushQuota: offlineQuotaSnap.exists ? withId(offlineQuotaSnap) : null,
    fcmTokens: fcmSnap.exists ? withId(fcmSnap) : null,
    leaderboards,
  });
});
