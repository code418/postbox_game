#!/usr/bin/env node
//
// import_postboxes.js — Import UK post box data from an Overpass API JSON
// file into the Firestore `postbox` collection.
//
// Usage:
//   node scripts/import_postboxes.js <path-to-overpass.json> [--dry-run]
//
// Prerequisites:
//   npm install firebase-admin ngeohash   (or use the versions in functions/)
//   export GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json
//   # OR set FIREBASE_PROJECT env var and run under `firebase use <project>`
//
// The input file must be an Overpass API JSON response with `elements` array.
// Each node with amenity=post_box becomes one Firestore document in `postbox`.
//
// Document ID: OSM node id (as string, e.g. "271462")
// Document fields:
//   geohash    — precision-9 ngeohash string
//   geopoint   — Firestore GeoPoint { _latitude, _longitude }
//   monarch    — royal_cypher tag value (e.g. "EIIR", "VR") or null
//   overpass_id — OSM numeric node id
//   reference  — ref tag value (e.g. "SO51 552") or null
//   post_box_type — post_box:type tag (e.g. "lamp", "wall") or null
//   collection_times — collection_times tag or null
//
// Firestore index required:
//   Collection: postbox  |  Field: geohash  |  Order: Ascending
//   (create via firebase.indexes.json or the Firestore console)
//
// Batch write limit: 500 per Firestore batch. Script batches accordingly.

'use strict';

const fs = require('fs');
const path = require('path');

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------
const args = process.argv.slice(2);
if (args.length === 0 || args.includes('--help')) {
  console.error('Usage: node scripts/import_postboxes.js <overpass.json> [--dry-run]');
  process.exit(1);
}
const inputFile = args.find(a => !a.startsWith('--'));
const dryRun = args.includes('--dry-run');

if (!inputFile || !fs.existsSync(inputFile)) {
  console.error(`File not found: ${inputFile}`);
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Lazy-load dependencies (so a missing dep gives a clear error)
// ---------------------------------------------------------------------------
let admin, ngeohash;
try {
  admin = require('firebase-admin');
} catch {
  // Try the functions node_modules as a fallback
  admin = require(path.join(__dirname, '../functions/node_modules/firebase-admin'));
}
try {
  ngeohash = require('ngeohash');
} catch {
  ngeohash = require(path.join(__dirname, '../functions/node_modules/ngeohash'));
}

// ---------------------------------------------------------------------------
// Firebase init
// ---------------------------------------------------------------------------
if (!admin.apps.length) {
  const projectId = process.env.FIREBASE_PROJECT || 'the-postbox-game';
  if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
    admin.initializeApp();
  } else {
    // Emulator / local dev: use application default credentials
    admin.initializeApp({ projectId });
  }
}
const db = admin.firestore();

// ---------------------------------------------------------------------------
// Parse input
// ---------------------------------------------------------------------------
console.log(`Reading ${inputFile}…`);
const raw = fs.readFileSync(inputFile, 'utf8');
const overpassData = JSON.parse(raw);
const elements = overpassData.elements ?? [];

const postboxNodes = elements.filter(
  el => el.type === 'node' && el.tags?.amenity === 'post_box'
);
console.log(`Found ${postboxNodes.length} post_box nodes out of ${elements.length} elements`);

if (postboxNodes.length === 0) {
  console.log('Nothing to import.');
  process.exit(0);
}

// ---------------------------------------------------------------------------
// Build documents
// ---------------------------------------------------------------------------
function buildDoc(node) {
  const { id, lat, lon, tags = {} } = node;
  const geohash = ngeohash.encode(lat, lon, 9);
  return {
    id: String(id),
    doc: {
      geohash,
      geopoint: new admin.firestore.GeoPoint(lat, lon),
      monarch: tags.royal_cypher ?? null,
      overpass_id: id,
      reference: tags.ref ?? null,
      post_box_type: tags['post_box:type'] ?? null,
      collection_times: tags.collection_times ?? null,
    },
  };
}

const docs = postboxNodes.map(buildDoc);

// ---------------------------------------------------------------------------
// Batch write (500 per batch — Firestore hard limit)
// ---------------------------------------------------------------------------
const BATCH_SIZE = 499;

async function importDocs() {
  const collection = db.collection('postbox');
  let written = 0;
  let skipped = 0;

  for (let i = 0; i < docs.length; i += BATCH_SIZE) {
    const chunk = docs.slice(i, i + BATCH_SIZE);
    const pct = Math.round(((i + chunk.length) / docs.length) * 100);
    process.stdout.write(`  Batch ${Math.floor(i / BATCH_SIZE) + 1}: writing ${chunk.length} docs… (${pct}%)\r`);

    if (dryRun) {
      written += chunk.length;
      continue;
    }

    const batch = db.batch();
    for (const { id, doc } of chunk) {
      batch.set(collection.doc(id), doc, { merge: false });
    }
    try {
      await batch.commit();
      written += chunk.length;
    } catch (err) {
      console.error(`\nBatch at offset ${i} failed:`, err.message);
      skipped += chunk.length;
    }
  }

  process.stdout.write('\n');
  console.log(`Done. Written: ${written}, Skipped: ${skipped}${dryRun ? ' (dry run)' : ''}`);
}

importDocs().catch(err => {
  console.error('Import failed:', err);
  process.exit(1);
});
