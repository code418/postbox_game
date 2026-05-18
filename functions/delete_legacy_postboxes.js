#!/usr/bin/env node
'use strict';

/**
 * delete_legacy_postboxes.js — delete `postbox/{id}` docs whose ID is neither
 * `osm_*` (OSM imports) nor `manual_*` (user-reported boxes from accepted
 * reports). Use to clean up stray/legacy doc IDs left over from earlier
 * import schemes.
 *
 * Usage (run from the functions/ directory):
 *
 *   node delete_legacy_postboxes.js [options]
 *
 * Options:
 *   --project <projectId>   Firebase project ID (default: the-postbox-game)
 *   --dry-run               Scan and report counts only, do not delete
 *   --yes                   Skip the interactive confirmation prompt
 *   --help                  Show this help
 *
 * Authentication: set GOOGLE_APPLICATION_CREDENTIALS to a service-account JSON
 * path, or run `gcloud auth application-default login` for ADC.
 */

const admin = require('firebase-admin');
const readline = require('readline');

const BATCH_SIZE = 400;
const SAMPLE_PRINT = 20;

function parseArgs(argv) {
  const opts = { projectId: 'the-postbox-game', dryRun: false, yes: false, help: false };
  const args = argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--project') opts.projectId = args[++i];
    else if (a === '--dry-run') opts.dryRun = true;
    else if (a === '--yes' || a === '-y') opts.yes = true;
    else if (a === '--help' || a === '-h') opts.help = true;
    else { console.error(`Unknown argument: ${a}`); opts.help = true; }
  }
  return opts;
}

function usage() {
  console.log('Usage: node delete_legacy_postboxes.js [--project <projectId>] [--dry-run] [--yes]');
}

function isLegacyId(id) {
  return !id.startsWith('osm_') && !id.startsWith('manual_');
}

async function confirm(prompt) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => rl.question(prompt, (ans) => { rl.close(); resolve(ans); }));
}

async function main() {
  const opts = parseArgs(process.argv);
  if (opts.help) { usage(); process.exit(0); }

  admin.initializeApp({ projectId: opts.projectId });
  const db = admin.firestore();
  const col = db.collection('postbox');

  console.log(`Scanning postbox collection in project "${opts.projectId}"…`);
  const refs = await col.listDocuments();
  const legacy = refs.filter((r) => isLegacyId(r.id));

  const osmCount = refs.filter((r) => r.id.startsWith('osm_')).length;
  const manualCount = refs.filter((r) => r.id.startsWith('manual_')).length;
  console.log(`Total docs: ${refs.length}`);
  console.log(`  osm_*:    ${osmCount} (kept)`);
  console.log(`  manual_*: ${manualCount} (kept)`);
  console.log(`  other:    ${legacy.length} (target)`);

  if (legacy.length === 0) {
    console.log('Nothing to delete.');
    return;
  }

  console.log(`\nSample of doc IDs to delete (up to ${SAMPLE_PRINT}):`);
  for (const r of legacy.slice(0, SAMPLE_PRINT)) console.log(`  - ${r.id}`);
  if (legacy.length > SAMPLE_PRINT) console.log(`  … and ${legacy.length - SAMPLE_PRINT} more`);

  if (opts.dryRun) {
    console.log('\n--dry-run set; not deleting.');
    return;
  }

  if (!opts.yes) {
    const ans = await confirm(`\nDelete ${legacy.length} docs from postbox? Type "yes" to proceed: `);
    if (ans.trim().toLowerCase() !== 'yes') {
      console.log('Aborted.');
      return;
    }
  }

  let deleted = 0;
  for (let i = 0; i < legacy.length; i += BATCH_SIZE) {
    const chunk = legacy.slice(i, i + BATCH_SIZE);
    const batch = db.batch();
    for (const ref of chunk) batch.delete(ref);
    await batch.commit();
    deleted += chunk.length;
    console.log(`Deleted ${deleted} / ${legacy.length}`);
  }

  console.log(`\nDone. Deleted ${deleted} legacy postbox docs.`);
}

main().catch((err) => {
  console.error(err && err.message ? err.message : err);
  process.exit(1);
});
