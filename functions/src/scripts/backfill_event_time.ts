/*
 * backfill_event_time.ts — one-off backfill that sets `eventTime = timestamp`
 * on every `claims` document that lacks it (ROADMAP v1.5, offline play
 * Phase 2).
 *
 * Background: v1.5 adds `eventTime` (when the user was physically at the box;
 * equal to the server write time for live claims) and switches the
 * travel-speed anti-spoof to eventTime-neighbour queries. Firestore EXCLUDES
 * documents missing the orderBy field, so until every historical claim
 * carries eventTime those queries return empty and the check silently no-ops
 * for the entire user base. ⚠️ This script MUST run to completion BEFORE the
 * v1.5 functions deploy switches the queries over.
 *
 * Docs missing a field can't be queried directly, so this scans the whole
 * claims collection ordered by timestamp with a cursor, patching only docs
 * without eventTime. Re-running is safe (idempotent): patched docs are
 * skipped.
 *
 * DRY-RUN BY DEFAULT: counts docs missing eventTime and writes nothing.
 * Pass --commit to apply (batched writes of up to --page-size).
 *
 * Run after `npm run build` (from functions/):
 *   node lib/scripts/backfill_event_time.js --project the-postbox-game            # dry-run
 *   node lib/scripts/backfill_event_time.js --project the-postbox-game --commit   # apply
 *   npm run backfill-event-time -- --project the-postbox-game --commit
 *
 * Auth: GOOGLE_APPLICATION_CREDENTIALS to a service-account JSON, or
 * `gcloud auth application-default login` for ADC. Targets the `(default)` DB.
 */

import * as admin from "firebase-admin";

interface Options {
  projectId: string;
  commit: boolean;
  pageSize: number;
  help: boolean;
}

function parseArgs(argv: string[]): Options {
  const args = argv.slice(2);
  const opts: Options = {
    projectId: "the-postbox-game",
    commit: false,
    pageSize: 400,
    help: false,
  };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--project") opts.projectId = args[++i];
    else if (a === "--commit") opts.commit = true;
    else if (a === "--page-size") opts.pageSize = Math.max(1, Math.min(500, Number(args[++i]) || 400));
    else if (a === "--help" || a === "-h") opts.help = true;
  }
  return opts;
}

const USAGE = `backfill_event_time — set claims.eventTime = timestamp where missing

  node lib/scripts/backfill_event_time.js [--project <id>] [--commit] [--page-size <n>]

  --project <id>   Firebase project ID (default: the-postbox-game)
  --commit         Actually write eventTime. Omit for a dry-run count.
  --page-size <n>  Docs per page/batch, 1..500 (default: 400)
  --help`;

async function main(): Promise<void> {
  const opts = parseArgs(process.argv);
  if (opts.help) {
    console.log(USAGE);
    return;
  }
  if (!admin.apps.length) admin.initializeApp({ projectId: opts.projectId });
  const db = admin.firestore();

  let scanned = 0;
  let missing = 0;
  let patched = 0;
  let cursor: FirebaseFirestore.QueryDocumentSnapshot | undefined;

  // Sequential by design: cursor pagination + one batch commit per page.
  /* eslint-disable no-await-in-loop */
  for (;;) {
    let q = db.collection("claims").orderBy("timestamp").limit(opts.pageSize);
    if (cursor) q = q.startAfter(cursor);
    const snap = await q.get();
    if (snap.empty) break;
    cursor = snap.docs[snap.docs.length - 1];
    scanned += snap.docs.length;

    const todo = snap.docs.filter((d) => d.data().eventTime === undefined);
    missing += todo.length;

    if (opts.commit && todo.length > 0) {
      const batch = db.batch();
      for (const doc of todo) {
        // eventTime := the immutable server write time — for a pre-v1.5 live
        // claim that IS when the user was there.
        batch.update(doc.ref, { eventTime: doc.data().timestamp });
      }
      await batch.commit();
      patched += todo.length;
    }
    console.log(`  …scanned ${scanned} (missing so far: ${missing}${opts.commit ? `, patched: ${patched}` : ""})`);
    if (snap.docs.length < opts.pageSize) break;
  }
  /* eslint-enable no-await-in-loop */

  console.log(
    opts.commit
      ? `Done. Patched eventTime on ${patched}/${scanned} claim doc(s).`
      : `DRY RUN: ${missing}/${scanned} claim doc(s) lack eventTime. Re-run with --commit to backfill.`,
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
