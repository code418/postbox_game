/*
 * strip_dailyclaim_by.ts — one-off cleanup that removes the legacy
 * `dailyClaim.by` field (the claimant's uid) from every `postbox` document.
 *
 * Background: claims used to write `postbox/{id}.dailyClaim.by = <uid>`.
 * `postbox` docs are world-readable (firestore.rules) and carry the exact
 * `geopoint`, and `users/{uid}.displayName` is world-readable too, so that uid
 * leaked "who was physically at <exact location> on <date>". `startScoring`
 * no longer writes it (see `dailyClaimPatch`); this script scrubs the values
 * left on historical docs. `dailyClaim.by` is never read anywhere, so removing
 * it is functionally invisible — only `dailyClaim.date` is kept.
 *
 * DRY-RUN BY DEFAULT: counts how many docs still carry `dailyClaim.by` and
 * writes nothing. Pass --commit to actually delete the field (batched).
 *
 * Run after `npm run build` (from functions/):
 *   node lib/scripts/strip_dailyclaim_by.js --project the-postbox-game            # dry-run (count only)
 *   node lib/scripts/strip_dailyclaim_by.js --project the-postbox-game --commit   # apply the cleanup
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

const USAGE = `strip_dailyclaim_by — remove legacy postbox.dailyClaim.by (claimant uid PII)

  node lib/scripts/strip_dailyclaim_by.js [--project <id>] [--commit] [--page-size <n>]

  --project <id>   Firebase project ID (default: the-postbox-game)
  --commit         Actually delete the field. Omit for a dry-run count.
  --page-size <n>  Docs per batch, 1..500 (default: 400)
  --help`;

async function main(): Promise<void> {
  const opts = parseArgs(process.argv);
  if (opts.help) {
    console.log(USAGE);
    return;
  }
  if (!admin.apps.length) admin.initializeApp({ projectId: opts.projectId });
  const db = admin.firestore();

  // orderBy on the nested field returns ONLY docs that have `dailyClaim.by`
  // (Firestore excludes docs missing an ordered field) — served by the
  // automatic single-field index, so no composite index is needed.
  const withBy = db.collection("postbox").orderBy("dailyClaim.by");

  if (!opts.commit) {
    const c = await withBy.count().get();
    const n = c.data().count;
    console.log(
      n === 0
        ? "DRY RUN: no postbox docs carry dailyClaim.by — nothing to do."
        : `DRY RUN: ${n} postbox doc(s) still carry dailyClaim.by. Re-run with --commit to remove.`,
    );
    return;
  }

  // Commit: repeatedly take the first page and delete the field. Deleting it
  // drops those docs out of the `orderBy("dailyClaim.by")` result set, so the
  // next query naturally surfaces the remaining ones — no cursor to drift.
  let removed = 0;
  // Sequential by necessity: each batch must delete the field (dropping those
  // docs from the orderBy result) before the next page is fetched, so these
  // awaits cannot be parallelised.
  /* eslint-disable no-await-in-loop */
  for (;;) {
    const snap = await withBy.limit(opts.pageSize).get();
    if (snap.empty) break;
    const batch = db.batch();
    for (const doc of snap.docs) {
      batch.update(doc.ref, { "dailyClaim.by": admin.firestore.FieldValue.delete() });
    }
    await batch.commit();
    removed += snap.docs.length;
    console.log(`  …cleared ${removed}`);
    if (snap.docs.length < opts.pageSize) break;
  }
  /* eslint-enable no-await-in-loop */
  console.log(`Done. Removed dailyClaim.by from ${removed} postbox doc(s).`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
