#!/usr/bin/env node
'use strict';

/**
 * import_postboxes.js — OSM → Firestore bulk + incremental import.
 *
 * Reads an Overpass API JSON export (amenity=post_box, UK) and writes each
 * node to the Firestore `postbox` collection using the schema expected by
 * _lookupPostboxes.ts:
 *
 *   { geohash, geopoint, overpass_id, monarch?, reference?, county? }
 *
 * Subsequent runs only write documents whose OSM data has changed since the
 * previous run, tracked via a local manifest of sha256(post-validation node
 * fields) keyed by OSM id. First-time runs (or runs with --no-manifest) write
 * every node.
 *
 * Usage (run from the functions/ directory so node_modules are resolvable):
 *
 *   node import_postboxes.js <input.json> [options]
 *
 * Options:
 *   --project  <projectId>          Firebase project ID (default: the-postbox-game)
 *   --limit    <N>                  Only consider the first N postboxes (testing)
 *   --dry-run                       Scan and report what would change without
 *                                   writing to Firestore or the manifest.
 *   --overwrite-corrections         Re-import even over docs flagged correctedBy
 *                                   (an admin's reviewReport correction). Default
 *                                   is to skip them so an OSM round-trip lag
 *                                   doesn't silently undo manual fixes.
 *   --prune                         Soft-mark osm_* Firestore docs whose OSM
 *                                   node has disappeared since the previous
 *                                   import by setting removedFromOsm + an
 *                                   removedFromOsmAt timestamp. Never hard-
 *                                   deletes — claims reference these IDs.
 *                                   Re-appearance auto-clears the flag (every
 *                                   normal write delete()s it).
 *   --manifest <path>               Override manifest location
 *                                   (default: functions/.last_import_manifest.json)
 *   --no-manifest                   Ignore any existing manifest; treat this
 *                                   run as a full re-import. A fresh manifest
 *                                   is still written at the end unless --dry-run.
 *   --help                          Show this help
 *
 * Authentication:
 *   Set GOOGLE_APPLICATION_CREDENTIALS to a service account JSON path, OR run
 *   `gcloud auth application-default login` for ADC.
 *
 * Example:
 *   cd functions
 *   node import_postboxes.js ../postboxes.json --project the-postbox-game
 */

const fs     = require('fs');
const path   = require('path');
const crypto = require('crypto');
const admin    = require('firebase-admin');
const geohash  = require('ngeohash');
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

// Manifest format version. Bump if the hash inputs or file shape change so
// older manifests are discarded rather than silently mis-skipping.
const MANIFEST_VERSION = 1;
const DEFAULT_MANIFEST_PATH = path.join(__dirname, '.last_import_manifest.json');

// ── Argument parsing ──────────────────────────────────────────────────────────

function parseArgs(argv) {
  const args = argv.slice(2);
  const opts = {
    file:      null,
    projectId: 'the-postbox-game',
    limit:     Infinity,
    dryRun:    false,
    overwriteCorrections: false,
    prune:        false,
    noManifest:   false,
    manifestPath: DEFAULT_MANIFEST_PATH,
  };

  let i = 0;
  while (i < args.length) {
    const a = args[i];
    if (a === '--project')                    { opts.projectId = args[++i]; }
    else if (a === '--limit')                 { opts.limit = parseInt(args[++i], 10); }
    else if (a === '--dry-run')               { opts.dryRun = true; }
    else if (a === '--overwrite-corrections') { opts.overwriteCorrections = true; }
    else if (a === '--prune')                 { opts.prune = true; }
    else if (a === '--no-manifest')           { opts.noManifest = true; }
    else if (a === '--manifest')              { opts.manifestPath = path.resolve(args[++i]); }
    else if (a === '--help' || a === '-h')    { printHelp(); process.exit(0); }
    else if (!a.startsWith('--'))             { opts.file = a; }
    i++;
  }
  return opts;
}

function printHelp() {
  console.log(`Usage: node import_postboxes.js <input.json> [options]

Options:
  --project  <projectId>          Firebase project ID (default: the-postbox-game)
  --limit    <N>                  Only consider first N postboxes (useful for testing)
  --dry-run                       Scan and report what would change; no writes
  --overwrite-corrections         Re-import even over docs flagged correctedBy
                                  (an admin's reviewReport correction). Default
                                  is to skip them so an OSM round-trip lag
                                  doesn't silently undo manual fixes.
  --prune                         Soft-mark osm_* docs whose OSM node has
                                  disappeared since the last import
                                  (sets removedFromOsm + removedFromOsmAt).
  --manifest <path>               Override manifest path
                                  (default: functions/.last_import_manifest.json)
  --no-manifest                   Ignore any existing manifest; full re-import
  --help                          Show this help

Authentication:
  Set GOOGLE_APPLICATION_CREDENTIALS=<path/to/serviceAccount.json>
  or run: gcloud auth application-default login

Example:
  cd functions
  node import_postboxes.js ../postboxes.json --project the-postbox-game
  node import_postboxes.js ../postboxes.json --dry-run`);
}

// ── Manifest helpers ──────────────────────────────────────────────────────────

function loadManifest(p) {
  if (!fs.existsSync(p)) return { version: MANIFEST_VERSION, nodes: {} };
  try {
    const data = JSON.parse(fs.readFileSync(p, 'utf8'));
    if (data?.version !== MANIFEST_VERSION || !data?.nodes) {
      console.warn(`Manifest at ${p} has unexpected shape — treating as empty.`);
      return { version: MANIFEST_VERSION, nodes: {} };
    }
    return data;
  } catch (err) {
    console.warn(`Failed to parse manifest at ${p} (${err.message}) — treating as empty.`);
    return { version: MANIFEST_VERSION, nodes: {} };
  }
}

function saveManifest(p, manifest) {
  // Atomic write: tmp + rename so a crash mid-write can't corrupt the manifest.
  const tmp = `${p}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(manifest, null, 2));
  fs.renameSync(tmp, p);
}

// ── Document builder ──────────────────────────────────────────────────────────

function buildDoc(node) {
  const gh = geohash.encode(node.lat, node.lon, GEOHASH_PRECISION);

  // Validate cipher against the game's known monarchs; unknown values import
  // without a monarch field (and score the default 2 pts).
  const rawCipher = (node.tags?.royal_cypher ?? '').toUpperCase().trim();
  const monarch = rawCipher && VALID_CIPHERS.has(rawCipher) ? rawCipher : null;

  const reference = (node.tags?.ref ?? '') || null;

  // countyForPoint returns null outside coverage (e.g. NI postboxes).
  const county = counties.countyForPoint(node.lat, node.lon) || null;

  // Hash uses the post-validation, canonically-ordered shape — null for any
  // field we'll explicit-delete. Stable across runs, agnostic to upstream OSM
  // tags we discard, and (via MANIFEST_VERSION) invalidated wholesale if these
  // inputs ever change.
  const hash = crypto.createHash('sha256').update(JSON.stringify({
    geohash: gh, lat: node.lat, lon: node.lon, monarch, reference, county,
  })).digest('hex');

  // Missing/invalid fields are FieldValue.delete()s so merge:true writes wipe
  // any stale value carried over from a prior import (e.g. the OSM tag was
  // corrected or removed since last time). Same applies to removedFromOsm:
  // any normal write clears the soft-prune mark, so a node reappearing in OSM
  // gets un-flagged automatically.
  const FieldValue = admin.firestore.FieldValue;
  const doc = {
    geohash:          gh,
    geopoint:         new admin.firestore.GeoPoint(node.lat, node.lon),
    overpass_id:      node.id,
    monarch:          monarch   ?? FieldValue.delete(),
    reference:        reference ?? FieldValue.delete(),
    county:           county    ?? FieldValue.delete(),
    removedFromOsm:   FieldValue.delete(),
    removedFromOsmAt: FieldValue.delete(),
  };

  return { hash, doc };
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

  admin.initializeApp({ projectId: opts.projectId });
  const db = admin.firestore();

  process.stderr.write(`Loading ${path.basename(filePath)}…`);
  const raw = fs.readFileSync(filePath, 'utf8');
  const data = JSON.parse(raw);
  process.stderr.write(' done.\n');

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
  console.log(`\nProcessing ${toImport.length.toLocaleString()} postboxes…`);

  // Load previous manifest (or start empty).
  const previousManifest = opts.noManifest
    ? { version: MANIFEST_VERSION, nodes: {} }
    : loadManifest(opts.manifestPath);
  const previousNodes = previousManifest.nodes;
  const nextNodes = {};

  // Build all docs up-front, then triage by hash vs the previous manifest.
  const built = toImport.map((node) => {
    const { hash, doc } = buildDoc(node);
    return { node, docId: `osm_${node.id}`, hash, doc };
  });

  const candidates = []; // hash differs from previous → needs Firestore write
  let inserted = 0;      // not in previous manifest
  let updated = 0;       // hash differs
  let unchanged = 0;     // hash matches
  for (const item of built) {
    nextNodes[item.node.id] = item.hash;
    const prev = previousNodes[item.node.id];
    if (prev === item.hash) {
      unchanged++;
      continue;
    }
    if (prev === undefined) inserted++;
    else updated++;
    candidates.push(item);
  }

  console.log(
    `  Triage: ${unchanged.toLocaleString()} unchanged · ${inserted.toLocaleString()} new · ${updated.toLocaleString()} updated`
  );

  // Batch-write only the candidates.
  const col = db.collection(COLLECTION);
  let written = 0;
  let skippedCorrected = 0;
  let writeFailures = 0;

  // Look up the existing correctedBy field for every doc we're about to write.
  // A bare read per chunk would gate writes on N round-trips; a getAll across
  // the chunk is one round-trip. We only need to know which docs to SKIP, so
  // an empty/missing snapshot just means "not corrected, write freely".
  async function correctedSetFor(chunk) {
    if (opts.overwriteCorrections) return new Set();
    const refs = chunk.map((it) => col.doc(it.docId));
    const snaps = await db.getAll(...refs);
    const corrected = new Set();
    for (const snap of snaps) {
      if (snap.exists && snap.data()?.correctedBy) corrected.add(snap.id);
    }
    return corrected;
  }

  if (!opts.dryRun && candidates.length > 0) {
    const start = Date.now();
    for (let i = 0; i < candidates.length; i += BATCH_SIZE) {
      const chunk = candidates.slice(i, i + BATCH_SIZE);
      const corrected = await correctedSetFor(chunk);
      const batch = db.batch();
      let writesInChunk = 0;
      for (const item of chunk) {
        if (corrected.has(item.docId)) {
          skippedCorrected++;
          // Keep the new OSM-derived hash in nextNodes so future runs match
          // and skip the getAll round-trip entirely. Trade-off: if the admin
          // later un-corrects the doc, the importer won't re-apply OSM data
          // until --no-manifest or --overwrite-corrections.
          continue;
        }
        batch.set(col.doc(item.docId), item.doc, { merge: true });
        writesInChunk++;
      }
      if (writesInChunk > 0) {
        try {
          await batch.commit();
          written += writesInChunk;
        } catch (err) {
          console.error(`\nBatch at offset ${i} failed:`, err.message);
          writeFailures += writesInChunk;
          // Drop these from the next manifest so the next run retries them.
          for (const item of chunk) {
            if (!corrected.has(item.docId)) delete nextNodes[item.node.id];
          }
        }
      }
      const processed = Math.min(i + chunk.length, candidates.length);
      const pct = ((processed / candidates.length) * 100).toFixed(1);
      const elapsed = ((Date.now() - start) / 1000).toFixed(0);
      process.stdout.write(
        `\r  ${written.toLocaleString()} written / ${processed.toLocaleString()} of ${candidates.length.toLocaleString()} candidates (${pct}%) — ${elapsed}s elapsed`
      );
    }
    process.stdout.write('\n');
  } else if (opts.dryRun && candidates.length > 0) {
    console.log('  (dry run: skipping Firestore writes)');
  }

  console.log('\nImport summary:');
  console.log(`  New postboxes inserted:      ${inserted.toLocaleString()}${opts.dryRun ? ' (would insert)' : ''}`);
  console.log(`  Updated (OSM data changed):  ${updated.toLocaleString()}${opts.dryRun ? ' (would update)' : ''}`);
  console.log(`  Skipped (no change):         ${unchanged.toLocaleString()}`);
  if (skippedCorrected > 0) {
    console.log(`  Skipped (admin-corrected):   ${skippedCorrected.toLocaleString()} (use --overwrite-corrections to force)`);
  }
  if (writeFailures > 0) {
    console.log(`  Write failures:              ${writeFailures.toLocaleString()}`);
  }

  // Nodes in the previous manifest but not in this OSM input.
  const inputIds = new Set(built.map((it) => String(it.node.id)));
  const missingFromOsm = Object.keys(previousNodes).filter((id) => !inputIds.has(id));

  if (opts.prune) {
    process.stderr.write('Scanning postbox collection for stale osm_* docs…');
    // .select() returns doc IDs without field data — minimal payload.
    const snap = await col.select().get();
    const stale = [];
    for (const ds of snap.docs) {
      if (!ds.id.startsWith('osm_')) continue; // skip manual_* and any other namespaces
      const osmId = ds.id.slice(4);
      if (!inputIds.has(osmId)) stale.push(ds.ref);
    }
    process.stderr.write(` found ${stale.length}.\n`);

    let marked = 0;
    if (!opts.dryRun && stale.length > 0) {
      const ts = admin.firestore.FieldValue.serverTimestamp();
      for (let i = 0; i < stale.length; i += BATCH_SIZE) {
        const chunk = stale.slice(i, i + BATCH_SIZE);
        const batch = db.batch();
        for (const ref of chunk) {
          batch.set(ref, { removedFromOsm: true, removedFromOsmAt: ts }, { merge: true });
        }
        try {
          await batch.commit();
          marked += chunk.length;
        } catch (err) {
          console.error(`\nPrune batch at offset ${i} failed:`, err.message);
        }
      }
    } else if (opts.dryRun) {
      marked = stale.length;
    }
    console.log(`  Marked removed from OSM:     ${marked.toLocaleString()}${opts.dryRun ? ' (would mark)' : ''}`);
  } else if (missingFromOsm.length > 0) {
    console.log(`  Missing from OSM (not pruned): ${missingFromOsm.length.toLocaleString()} (run with --prune to soft-mark)`);
  }

  // Persist the manifest. Includes hashes for unchanged, written, AND
  // correctedBy-skipped items, so each run is a fresh snapshot of what the
  // current OSM file says these nodes should be.
  if (!opts.dryRun) {
    saveManifest(opts.manifestPath, {
      version: MANIFEST_VERSION,
      generatedAt: new Date().toISOString(),
      sourceFile: path.basename(filePath),
      nodes: nextNodes,
    });
    console.log(`Manifest written to: ${opts.manifestPath}`);
  } else {
    console.log('(dry run: manifest not written)');
  }

  // Only persist the total count when importing without a --limit so the
  // stored value reflects the full dataset (not a subset used for testing).
  // Read the actual collection count rather than `written` — that figure
  // excludes both the docs we skipped (correctedBy) and the manual_* docs
  // added by accepted missing-postbox reports, so using it as the lifetime
  // leaderboard's "X of Y" denominator would silently undercount.
  if (opts.limit === Infinity && !opts.dryRun) {
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
