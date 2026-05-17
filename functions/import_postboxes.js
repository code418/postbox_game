#!/usr/bin/env node
'use strict';

/**
 * import_postboxes.js — OSM → Firestore bulk import
 *
 * Reads an Overpass API JSON export (amenity=post_box, UK) and batch-writes
 * each node to the Firestore `postbox` collection using the schema expected
 * by _lookupPostboxes.ts:
 *
 *   { geohash, geopoint: GeoPoint, monarch?, reference?, overpass_id }
 *
 * Usage (run from the functions/ directory so node_modules are resolvable):
 *
 *   node import_postboxes.js <input.json> [options]
 *
 * Options:
 *   --project  <projectId>   Firebase project ID (default: the-postbox-game)
 *   --limit    <N>           Only import the first N postboxes (for testing)
 *   --dry-run                Parse and show sample docs without writing
 *   --help                   Show this help
 *
 * Authentication:
 *   Set GOOGLE_APPLICATION_CREDENTIALS to a service account JSON path, OR run
 *   `gcloud auth application-default login` for ADC.
 *
 * Example:
 *   cd functions
 *   node import_postboxes.js ../postboxes.json --project the-postbox-game
 */

const fs   = require('fs');
const path = require('path');
const admin   = require('firebase-admin');
const geohash = require('ngeohash');
const counties = require('./util/county_lookup');

// ── Config ────────────────────────────────────────────────────────────────────

// Firestore collection name — must match _lookupPostboxes.ts
const COLLECTION = 'postbox';

// Geohash precision for the spatial index.
// Must be >= the highest precision returned by setPrecision() in _lookupPostboxes.ts.
// Stored geohashes are prefix-matched against lower-precision query ranges, so
// the stored precision must be at least as specific as the most precise lookup.
// A previous bug stored at precision 6: precision-8 prefix queries sorted above
// those stored hashes, so claims returned no results. Precision 9 (~4.8 m cells)
// is the maximum and guarantees any lower-precision prefix query (8, 7, 6…)
// still matches stored documents.
const GEOHASH_PRECISION = 9;

// Maximum documents per batch write (Firestore limit is 500).
const BATCH_SIZE = 400;

// Royal ciphers recognised by the game (_getPoints.ts + MonarchInfo.all).
// Postboxes with other cipher values (scottish_crown, obscured, …) are still
// imported but without a `monarch` field — they score 2 pts (the default).
const VALID_CIPHERS = new Set([
  'EIIR', 'CIIIR', 'GR', 'GVR', 'GVIR', 'VR', 'EVIIR', 'EVIIIR',
  'SCOTTISH_CROWN',
]);

// ── Argument parsing ──────────────────────────────────────────────────────────

function parseArgs(argv) {
  const args = argv.slice(2);
  const opts = {
    file:      null,
    projectId: 'the-postbox-game',
    limit:     Infinity,
    dryRun:    false,
    overwriteCorrections: false,
  };

  let i = 0;
  while (i < args.length) {
    const a = args[i];
    if (a === '--project')  { opts.projectId = args[++i]; }
    else if (a === '--limit')    { opts.limit = parseInt(args[++i], 10); }
    else if (a === '--dry-run')  { opts.dryRun = true; }
    else if (a === '--overwrite-corrections') { opts.overwriteCorrections = true; }
    else if (a === '--help' || a === '-h') { printHelp(); process.exit(0); }
    else if (!a.startsWith('--')) { opts.file = a; }
    i++;
  }
  return opts;
}

function printHelp() {
  console.log(`Usage: node import_postboxes.js <input.json> [options]

Options:
  --project  <projectId>          Firebase project ID (default: the-postbox-game)
  --limit    <N>                  Only import first N postboxes (useful for testing)
  --dry-run                       Parse and show 5 sample docs without writing
  --overwrite-corrections         Re-import even over docs flagged correctedBy
                                  (an admin's reviewReport correction). Default
                                  is to skip them so an OSM round-trip lag
                                  doesn't silently undo manual fixes.
  --help                          Show this help

Authentication:
  Set GOOGLE_APPLICATION_CREDENTIALS=<path/to/serviceAccount.json>
  or run: gcloud auth application-default login

Example:
  cd functions
  node import_postboxes.js ../postboxes.json --project the-postbox-game
  node import_postboxes.js ../postboxes.json --dry-run --limit 5`);
}

// ── Document builder ──────────────────────────────────────────────────────────

function buildDoc(node) {
  const gh = geohash.encode(node.lat, node.lon, GEOHASH_PRECISION);
  const doc = {
    geohash:    gh,
    geopoint:   new admin.firestore.GeoPoint(node.lat, node.lon),
    overpass_id: node.id,
  };

  const rawCipher = node.tags?.royal_cypher ?? '';
  // Normalise to upper-case; only store known ciphers so the game's points
  // table and UI labels always match.
  const cipher = rawCipher.toUpperCase().trim();
  if (cipher && VALID_CIPHERS.has(cipher)) {
    doc.monarch = cipher;
  } else {
    // Explicitly delete any stale monarch field so that a reimport (which uses
    // merge:true) removes it when the OSM data no longer has a known cipher.
    // Without this, a postbox previously tagged e.g. EIIR would keep that
    // value in Firestore even after the OSM tag is corrected or removed.
    doc.monarch = admin.firestore.FieldValue.delete();
  }

  const ref = node.tags?.ref ?? '';
  // Same as monarch: explicitly delete stale reference values on reimport.
  doc.reference = ref || admin.firestore.FieldValue.delete();

  // County tagging (UK counties / unitary authorities). countyForPoint returns
  // null for points outside coverage (e.g. NI postboxes); explicit delete keeps
  // re-imports idempotent.
  const county = counties.countyForPoint(node.lat, node.lon);
  doc.county = county || admin.firestore.FieldValue.delete();

  return doc;
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main() {
  const opts = parseArgs(process.argv);

  if (!opts.file) {
    printHelp();
    process.exit(1);
  }

  const filePath = path.resolve(opts.file);
  if (!fs.existsSync(filePath)) {
    console.error(`Error: file not found: ${filePath}`);
    process.exit(1);
  }

  // Initialise Firebase Admin SDK.
  admin.initializeApp({ projectId: opts.projectId });
  const db = admin.firestore();

  // Load and parse the Overpass JSON.
  process.stderr.write(`Loading ${path.basename(filePath)}…`);
  const raw = fs.readFileSync(filePath, 'utf8');
  const data = JSON.parse(raw);
  process.stderr.write(' done.\n');

  // Load county polygons up-front so per-postbox lookups are zero-cost-ish.
  const featureCount = counties.load().length;
  console.log(`Loaded ${featureCount} UK county polygons.`);

  const elements = data.elements ?? [];
  const postboxes = elements.filter(
    (e) => e.type === 'node' && e.lat != null && e.lon != null
  );

  console.log(`Found ${postboxes.length.toLocaleString()} postbox nodes.`);

  // Cipher breakdown for informational purposes.
  const cipherCounts = {};
  for (const p of postboxes) {
    const c = p.tags?.royal_cypher ?? '(none)';
    cipherCounts[c] = (cipherCounts[c] ?? 0) + 1;
  }
  const top = Object.entries(cipherCounts)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 8);
  console.log('Cipher breakdown (top 8):');
  for (const [c, n] of top) {
    const star = VALID_CIPHERS.has(c.toUpperCase()) ? ' ✓' : '';
    console.log(`  ${c.padEnd(18)} ${n.toLocaleString()}${star}`);
  }

  const toImport = postboxes.slice(0, opts.limit);
  console.log(`\nImporting ${toImport.length.toLocaleString()} postboxes…`);

  if (opts.dryRun) {
    console.log('\n[DRY RUN] Sample documents (no writes performed):');
    const sample = toImport.slice(0, 5);
    for (const node of sample) {
      const docId = `osm_${node.id}`;
      const doc = buildDoc(node);
      // Substitute FieldValue sentinels with a readable placeholder for dry-run display.
      const FieldValue = admin.firestore.FieldValue;
      const display = Object.fromEntries(
        Object.entries({ ...doc, geopoint: `GeoPoint(${node.lat}, ${node.lon})` })
          .map(([k, v]) => [k, (v instanceof FieldValue) ? '<delete>' : v])
      );
      console.log(`  ${docId}:`, JSON.stringify(display));
    }
    return;
  }

  // Batch-write in chunks.
  const col = db.collection(COLLECTION);
  let written = 0;
  let skippedCorrected = 0;
  const start = Date.now();

  // Look up the existing correctedBy field for every doc we're about to write.
  // A bare read per chunk would gate writes on N round-trips; a getAll across
  // the chunk is one round-trip. We only need to know which docs to SKIP, so
  // an empty/missing snapshot just means "not corrected, write freely".
  async function correctedSetFor(chunk) {
    if (opts.overwriteCorrections) return new Set();
    const refs = chunk.map((node) => col.doc(`osm_${node.id}`));
    const snaps = await db.getAll(...refs);
    const corrected = new Set();
    for (const snap of snaps) {
      if (snap.exists && snap.data()?.correctedBy) corrected.add(snap.id);
    }
    return corrected;
  }

  for (let i = 0; i < toImport.length; i += BATCH_SIZE) {
    const chunk = toImport.slice(i, i + BATCH_SIZE);
    const corrected = await correctedSetFor(chunk);
    const batch = db.batch();
    let writesInChunk = 0;
    for (const node of chunk) {
      const docId = `osm_${node.id}`;
      if (corrected.has(docId)) {
        skippedCorrected++;
        continue;
      }
      batch.set(col.doc(docId), buildDoc(node), { merge: true });
      writesInChunk++;
    }
    if (writesInChunk > 0) await batch.commit();
    written += writesInChunk;
    const processed = i + chunk.length;
    const pct = ((processed / toImport.length) * 100).toFixed(1);
    const elapsed = ((Date.now() - start) / 1000).toFixed(0);
    process.stdout.write(`\r  ${written.toLocaleString()} written / ${processed.toLocaleString()} of ${toImport.length.toLocaleString()} (${pct}%) — ${elapsed}s elapsed`);
  }
  if (skippedCorrected > 0) {
    console.log(`\n  Skipped ${skippedCorrected.toLocaleString()} doc(s) flagged correctedBy (use --overwrite-corrections to force).`);
  }

  const totalSecs = ((Date.now() - start) / 1000).toFixed(1);
  console.log(`\n\nImport complete. Wrote ${written.toLocaleString()} postboxes in ${totalSecs}s.`);
  console.log(`Collection: ${COLLECTION}`);

  // Only persist the total count when importing without a --limit so the
  // stored value reflects the full dataset (not a subset used for testing).
  // Read the actual collection count rather than `written` — that figure
  // excludes both the docs we skipped (correctedBy) and the manual_* docs
  // added by accepted missing-postbox reports, so using it as the lifetime
  // leaderboard's "X of Y" denominator would silently undercount.
  if (opts.limit === Infinity) {
    const countSnap = await col.count().get();
    const totalPostboxes = countSnap.data().count;
    await db.collection('meta').doc('stats').set(
      { totalPostboxes },
      { merge: true }
    );
    console.log(`meta/stats.totalPostboxes updated to ${totalPostboxes.toLocaleString()} (collection count).`);
  }
}

main().catch((err) => {
  console.error('\nImport failed:', err.message ?? err);
  process.exit(1);
});
