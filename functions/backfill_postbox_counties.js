#!/usr/bin/env node
'use strict';

/**
 * backfill_postbox_counties.js — one-off script that walks the `postbox`
 * collection and writes a `county` field on each doc whose geopoint resolves
 * inside a UK county / unitary authority polygon (see util/county_lookup.js).
 *
 * Existing imports predate the county-tagging change in import_postboxes.js,
 * so this is required to seed the new field for documents already in
 * Firestore. Idempotent: docs that already have the same county are skipped.
 *
 * Usage:
 *   cd functions
 *   node backfill_postbox_counties.js [--project the-postbox-game] [--dry-run] [--limit N]
 *
 * Auth: GOOGLE_APPLICATION_CREDENTIALS=… or `gcloud auth application-default login`.
 */

const admin = require('firebase-admin');
const counties = require('./util/county_lookup');

const COLLECTION = 'postbox';
const PAGE_SIZE = 500;
const BATCH_SIZE = 400;

function parseArgs(argv) {
  const opts = { projectId: 'the-postbox-game', dryRun: false, limit: Infinity };
  const args = argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--project') opts.projectId = args[++i];
    else if (a === '--dry-run') opts.dryRun = true;
    else if (a === '--limit') opts.limit = parseInt(args[++i], 10);
    else if (a === '--help' || a === '-h') { printHelp(); process.exit(0); }
  }
  return opts;
}

function printHelp() {
  console.log(`Usage: node backfill_postbox_counties.js [options]

Options:
  --project <id>   Firebase project ID (default: the-postbox-game)
  --dry-run        Read and report changes without writing
  --limit <N>      Stop after processing N postboxes
  --help           Show this help`);
}

function getLatLng(geopoint) {
  if (!geopoint) return null;
  // Admin GeoPoint exposes latitude/longitude; raw maps may have either case.
  const lat = typeof geopoint.latitude === 'number' ? geopoint.latitude : geopoint._latitude;
  const lng = typeof geopoint.longitude === 'number' ? geopoint.longitude : geopoint._longitude;
  if (typeof lat !== 'number' || typeof lng !== 'number') return null;
  return { lat, lng };
}

async function main() {
  const opts = parseArgs(process.argv);
  admin.initializeApp({ projectId: opts.projectId });
  const db = admin.firestore();

  const featureCount = counties.load().length;
  console.log(`Loaded ${featureCount} UK county polygons.`);

  const col = db.collection(COLLECTION);
  let lastDoc = null;
  let scanned = 0;
  let updated = 0;
  let skipped = 0;
  let unmatched = 0;
  let pendingBatch = db.batch();
  let pendingCount = 0;

  const flush = async () => {
    if (pendingCount === 0) return;
    if (!opts.dryRun) await pendingBatch.commit();
    pendingBatch = db.batch();
    pendingCount = 0;
  };

  const start = Date.now();
  while (scanned < opts.limit) {
    const remaining = opts.limit - scanned;
    const pageSize = Math.min(PAGE_SIZE, remaining);
    let q = col.orderBy(admin.firestore.FieldPath.documentId()).limit(pageSize);
    if (lastDoc) q = q.startAfter(lastDoc);
    const snap = await q.get();
    if (snap.empty) break;

    for (const doc of snap.docs) {
      scanned++;
      const data = doc.data();
      const geo = getLatLng(data.geopoint);
      if (!geo) { unmatched++; continue; }
      const county = counties.countyForPoint(geo.lat, geo.lng);
      if (!county) { unmatched++; continue; }
      if (data.county === county) { skipped++; continue; }

      pendingBatch.set(doc.ref, { county }, { merge: true });
      pendingCount++;
      updated++;
      if (pendingCount >= BATCH_SIZE) await flush();
    }

    lastDoc = snap.docs[snap.docs.length - 1];
    const elapsed = ((Date.now() - start) / 1000).toFixed(0);
    process.stdout.write(`\r  scanned=${scanned} updated=${updated} skipped=${skipped} unmatched=${unmatched}  ${elapsed}s`);
    if (snap.size < pageSize) break;
  }
  await flush();

  console.log(`\n\nDone. Scanned ${scanned}, updated ${updated}, already-current ${skipped}, no-county ${unmatched}.`);
  if (opts.dryRun) console.log('(dry run — no writes performed)');
}

main().catch((err) => {
  console.error('\nBackfill failed:', err.stack || err.message || err);
  process.exit(1);
});
