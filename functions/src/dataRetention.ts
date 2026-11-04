// Scheduled GDPR retention sweep — Art. 5(1)(e) storage limitation.
//
// Retention policy (documented in the privacy policy; keep the two in sync):
//   claims        — location/timing/device PII fields stripped after 90 days
//                   (CLAIM_PII_FIELDS from _accountDeletion.ts; the claim record
//                   itself, points/monarch/dailyDate, is kept for game history)
//   reports       — photos (Storage blobs + doc array) and free-text note
//                   removed 30 days after review (pending reports untouched)
//   moderationFlags — deleted whole after 180 days
//
// Mechanics: nightly onSchedule at 03:30 Europe/London (avoids the 00:00
// newDayScoreboard rollover). Claims and reports use a persistent WATERMARK
// (retention/{claimsSweep,reportsSweep}) so the sweep never rescans ranges it
// has already processed: each run pages forward from the watermark to the
// cutoff with a document cursor, persisting the watermark after every page
// (crash-safe resume; a re-run only re-reads docs sharing the boundary
// timestamp, which the needs-strip predicates then skip). Invariant this relies
// on: claims/reports are only ever written with server-side `Timestamp.now()`
// timestamps (startScoring.ts / reports.ts) — nothing back-dates a doc behind
// the watermark. moderationFlags need no watermark (deletion is self-cleaning).
//
// Firestore TTL (fieldOverrides + an expiresAt field) was considered for the
// flags and rejected for now: existing docs carry no expiry field (a backfill
// would be sweep-like code anyway), TTL deletes lag up to ~72 h and emit no
// compliance-evidence logs, and shadow-mode flag volume is tiny. Revisit if
// volume grows.

import "./adminInit";
import * as admin from "firebase-admin";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { CLAIM_PII_FIELDS, REPORT_PII_FIELDS } from "./_accountDeletion";

type Firestore = admin.firestore.Firestore;

export const CLAIM_PII_RETENTION_DAYS = 90;
export const REPORT_MEDIA_RETENTION_DAYS = 30; // after review
export const FLAG_RETENTION_DAYS = 180;

/** Docs fetched per query page. */
export const PAGE_SIZE = 300;
/** Pages processed per collection per nightly run (backfill drains gradually). */
export const MAX_PAGES_PER_RUN = 20;
const WRITE_BATCH_SIZE = 400; // matches _accountDeletion.ts
const DAY_MS = 24 * 60 * 60 * 1000;

/** Minimal structural view of a Storage bucket so tests can inject a fake. */
export interface StorageBucketLike {
  file(path: string): { delete(): Promise<unknown> };
}

/** Page-size/page-count overrides for tests. */
export interface SweepOptions {
  pageSize?: number;
  maxPages?: number;
}

export interface ClaimSweepResult {
  scanned: number;
  stripped: number;
  pagesRemaining: boolean;
}

export interface ReportSweepResult {
  scanned: number;
  purged: number;
  filesDeleted: number;
  pagesRemaining: boolean;
}

export interface FlagSweepResult {
  deleted: number;
  pagesRemaining: boolean;
}

/** True when the claim still carries any PII field the sweep must strip.
 *  Already-anonymised claims (account deletion) and already-swept claims
 *  return false, keeping re-reads of watermark-boundary docs write-free. */
export function claimNeedsPiiStrip(data: Record<string, unknown>): boolean {
  return CLAIM_PII_FIELDS.some((f) => f in data);
}

/** True when the report still carries purgeable media/note fields. */
export function reportNeedsMediaPurge(data: Record<string, unknown>): boolean {
  return REPORT_PII_FIELDS.some((f) => f in data);
}

/** The Storage paths of a report's photos ([] when none/malformed). */
export function reportStoragePaths(data: Record<string, unknown>): string[] {
  const photos = data.photos;
  if (!Array.isArray(photos)) return [];
  return photos
    .map((p) =>
      p !== null && typeof p === "object" ? (p as Record<string, unknown>).storagePath : undefined,
    )
    .filter((s): s is string => typeof s === "string" && s.length > 0);
}

/** Read the persisted watermark for [stateDocId] (epoch 0 on first run). */
async function readWatermark(db: Firestore, stateDocId: string): Promise<admin.firestore.Timestamp> {
  const snap = await db.collection("retention").doc(stateDocId).get();
  const wm = snap.data()?.watermark as admin.firestore.Timestamp | undefined;
  return wm ?? admin.firestore.Timestamp.fromMillis(0);
}

async function writeWatermark(db: Firestore, stateDocId: string, wm: admin.firestore.Timestamp): Promise<void> {
  await db.collection("retention").doc(stateDocId).set(
    { watermark: wm, updatedAt: admin.firestore.FieldValue.serverTimestamp() },
    { merge: true },
  );
}

/** Commit [refs]→[update] merge-sets in WRITE_BATCH_SIZE chunks. */
async function batchedMergeSet(
  db: Firestore,
  targets: Array<{ ref: FirebaseFirestore.DocumentReference; update: Record<string, unknown> }>,
): Promise<void> {
  const batches: admin.firestore.WriteBatch[] = [];
  for (let i = 0; i < targets.length; i += WRITE_BATCH_SIZE) {
    const batch = db.batch();
    for (const t of targets.slice(i, i + WRITE_BATCH_SIZE)) batch.set(t.ref, t.update, { merge: true });
    batches.push(batch);
  }
  await Promise.all(batches.map((b) => b.commit()));
}

export async function sweepClaimPii(
  db: Firestore,
  nowMs: number,
  opts: SweepOptions = {},
): Promise<ClaimSweepResult> {
  const pageSize = opts.pageSize ?? PAGE_SIZE;
  const maxPages = opts.maxPages ?? MAX_PAGES_PER_RUN;
  const cutoff = admin.firestore.Timestamp.fromMillis(nowMs - CLAIM_PII_RETENTION_DAYS * DAY_MS);
  const watermark = await readWatermark(db, "claimsSweep");

  const stripUpdate: Record<string, unknown> = {};
  for (const f of CLAIM_PII_FIELDS) stripUpdate[f] = admin.firestore.FieldValue.delete();

  let scanned = 0;
  let stripped = 0;
  let cursor: FirebaseFirestore.QueryDocumentSnapshot | undefined;
  for (let page = 0; page < maxPages; page++) {
    let q = db
      .collection("claims")
      .where("timestamp", ">=", watermark)
      .where("timestamp", "<", cutoff)
      .orderBy("timestamp")
      .limit(pageSize);
    if (cursor !== undefined) q = q.startAfter(cursor);
    // Pages are inherently sequential: each depends on the previous cursor, and
    // the watermark must land before the next page for crash-safe resume.
    // eslint-disable-next-line no-await-in-loop
    const snap = await q.get();
    if (snap.docs.length === 0) return { scanned, stripped, pagesRemaining: false };

    scanned += snap.docs.length;
    const dirty = snap.docs.filter((d) => claimNeedsPiiStrip(d.data()));
    // eslint-disable-next-line no-await-in-loop
    await batchedMergeSet(db, dirty.map((d) => ({ ref: d.ref, update: stripUpdate })));
    stripped += dirty.length;

    cursor = snap.docs[snap.docs.length - 1];
    // eslint-disable-next-line no-await-in-loop
    await writeWatermark(db, "claimsSweep", cursor.data().timestamp as admin.firestore.Timestamp);
    if (snap.docs.length < pageSize) return { scanned, stripped, pagesRemaining: false };
  }
  return { scanned, stripped, pagesRemaining: true };
}

export async function sweepReportMedia(
  db: Firestore,
  bucket: StorageBucketLike,
  nowMs: number,
  opts: SweepOptions = {},
): Promise<ReportSweepResult> {
  const pageSize = opts.pageSize ?? PAGE_SIZE;
  const maxPages = opts.maxPages ?? MAX_PAGES_PER_RUN;
  const cutoff = admin.firestore.Timestamp.fromMillis(nowMs - REPORT_MEDIA_RETENTION_DAYS * DAY_MS);
  const watermark = await readWatermark(db, "reportsSweep");

  let scanned = 0;
  let purged = 0;
  let filesDeleted = 0;
  let cursor: FirebaseFirestore.QueryDocumentSnapshot | undefined;
  for (let page = 0; page < maxPages; page++) {
    // Pending reports never have `reviewedAt`, so the range query structurally
    // excludes them — only reviewed reports age out.
    let q = db
      .collection("reports")
      .where("reviewedAt", ">=", watermark)
      .where("reviewedAt", "<", cutoff)
      .orderBy("reviewedAt")
      .limit(pageSize);
    if (cursor !== undefined) q = q.startAfter(cursor);
    // Sequential paging — same cursor/watermark reasoning as sweepClaimPii.
    // eslint-disable-next-line no-await-in-loop
    const snap = await q.get();
    if (snap.docs.length === 0) return { scanned, purged, filesDeleted, pagesRemaining: false };

    scanned += snap.docs.length;
    const toPurge = snap.docs.filter((d) => reportNeedsMediaPurge(d.data()));

    // Delete the Storage blobs first so a crash between the two steps leaves
    // the doc still flagged for purge (re-run safe), never orphaned blobs.
    for (const doc of toPurge) {
      for (const path of reportStoragePaths(doc.data())) {
        try {
          // Deliberately serial: bounds Storage concurrency on a background job.
          // eslint-disable-next-line no-await-in-loop
          await bucket.file(path).delete();
          filesDeleted++;
        } catch {
          // Already gone (e.g. the reporter deleted their account) — fine.
        }
      }
    }

    const purgedAt = admin.firestore.Timestamp.fromMillis(nowMs);
    const update: Record<string, unknown> = { mediaPurgedAt: purgedAt };
    for (const f of REPORT_PII_FIELDS) update[f] = admin.firestore.FieldValue.delete();
    // eslint-disable-next-line no-await-in-loop
    await batchedMergeSet(db, toPurge.map((d) => ({ ref: d.ref, update })));
    purged += toPurge.length;

    cursor = snap.docs[snap.docs.length - 1];
    // eslint-disable-next-line no-await-in-loop
    await writeWatermark(db, "reportsSweep", cursor.data().reviewedAt as admin.firestore.Timestamp);
    if (snap.docs.length < pageSize) return { scanned, purged, filesDeleted, pagesRemaining: false };
  }
  return { scanned, purged, filesDeleted, pagesRemaining: true };
}

export async function sweepModerationFlags(
  db: Firestore,
  nowMs: number,
  opts: SweepOptions = {},
): Promise<FlagSweepResult> {
  const pageSize = opts.pageSize ?? PAGE_SIZE;
  const maxPages = opts.maxPages ?? MAX_PAGES_PER_RUN;
  const cutoff = admin.firestore.Timestamp.fromMillis(nowMs - FLAG_RETENTION_DAYS * DAY_MS);

  let deleted = 0;
  for (let page = 0; page < maxPages; page++) {
    // No watermark: deletion is self-cleaning (removed docs leave the result
    // set), so each page re-queries from the top — sequential by design.
    // eslint-disable-next-line no-await-in-loop
    const snap = await db
      .collection("moderationFlags")
      .where("createdAt", "<", cutoff)
      .orderBy("createdAt")
      .limit(pageSize)
      .get();
    if (snap.docs.length === 0) return { deleted, pagesRemaining: false };

    const batches: admin.firestore.WriteBatch[] = [];
    for (let i = 0; i < snap.docs.length; i += WRITE_BATCH_SIZE) {
      const batch = db.batch();
      for (const doc of snap.docs.slice(i, i + WRITE_BATCH_SIZE)) batch.delete(doc.ref);
      batches.push(batch);
    }
    // eslint-disable-next-line no-await-in-loop
    await Promise.all(batches.map((b) => b.commit()));
    deleted += snap.docs.length;
    if (snap.docs.length < pageSize) return { deleted, pagesRemaining: false };
  }
  return { deleted, pagesRemaining: true };
}

/** Nightly retention sweep. Three independent phases — a failure in one must
 *  not stop the others; each logs its counts for compliance evidence. */
export const dataRetentionSweep = onSchedule(
  { schedule: "30 3 * * *", timeZone: "Europe/London" },
  async () => {
    const db = admin.firestore();
    const nowMs = Date.now();
    try {
      const r = await sweepClaimPii(db, nowMs);
      console.log(`[retention] claims: scanned=${r.scanned} stripped=${r.stripped} more=${r.pagesRemaining}`);
    } catch (e) {
      console.error("[retention] claim sweep failed:", e);
    }
    try {
      const r = await sweepReportMedia(db, admin.storage().bucket(), nowMs);
      console.log(`[retention] reports: scanned=${r.scanned} purged=${r.purged} files=${r.filesDeleted} more=${r.pagesRemaining}`);
    } catch (e) {
      console.error("[retention] report sweep failed:", e);
    }
    try {
      const r = await sweepModerationFlags(db, nowMs);
      console.log(`[retention] flags: deleted=${r.deleted} more=${r.pagesRemaining}`);
    } catch (e) {
      console.error("[retention] flag sweep failed:", e);
    }
  },
);
