#!/usr/bin/env node
'use strict';

/**
 * backfill_county_leaderboards.js — one-off rebuild of the per-county
 * lifetime stats and leaderboards from the historical claims collection.
 *
 * Required after deploying per-county tagging so existing users have credit
 * for past claims. Run AFTER backfill_postbox_counties.js (the postbox
 * `county` field must exist before this script can attribute claims).
 *
 * Writes:
 *   users/{uid}/countyStats/{slug} = { county, uniquePostboxesClaimed,
 *                                      totalPoints, updatedAt }
 *   leaderboards/lifetime_by_county/counties/{slug} = { county, entries: [...] }
 *
 * Idempotent — safe to re-run; each run computes from claims and overwrites.
 *
 * Usage:
 *   cd functions
 *   node backfill_county_leaderboards.js [--project the-postbox-game] [--dry-run] [--county <slug>]
 *
 * Auth: GOOGLE_APPLICATION_CREDENTIALS=… or `gcloud auth application-default login`.
 */

const admin = require('firebase-admin');

const CLAIM_PAGE_SIZE = 1000;
const POSTBOX_PAGE_SIZE = 500;
const ENTRY_LIMIT = 100;
const BATCH_SIZE = 400;

function parseArgs(argv) {
  const opts = {
    projectId: 'the-postbox-game',
    dryRun: false,
    countySlug: null,
  };
  const args = argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--project') opts.projectId = args[++i];
    else if (a === '--dry-run') opts.dryRun = true;
    else if (a === '--county') opts.countySlug = args[++i];
    else if (a === '--help' || a === '-h') { printHelp(); process.exit(0); }
  }
  return opts;
}

function printHelp() {
  console.log(`Usage: node backfill_county_leaderboards.js [options]

Options:
  --project <id>      Firebase project ID (default: the-postbox-game)
  --dry-run           Aggregate and report without writing
  --county <slug>     Rebuild a single county only (e.g. cornwall)
  --help              Show this help`);
}

function slug(name) {
  if (!name) return null;
  const s = String(name).toLowerCase()
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '');
  return s || null;
}

async function loadPostboxCounties(db) {
  // Map each postbox doc id → its county. We keep this in memory; even with
  // 100k+ postboxes this is well under 50 MB and avoids ~N reads inside the
  // claims loop (claims dwarf postboxes).
  const map = new Map();
  let last = null;
  let scanned = 0;
  const start = Date.now();
  while (true) {
    let q = db.collection('postbox')
      .orderBy(admin.firestore.FieldPath.documentId())
      .limit(POSTBOX_PAGE_SIZE);
    if (last) q = q.startAfter(last);
    const snap = await q.get();
    if (snap.empty) break;
    for (const d of snap.docs) {
      const c = d.data().county;
      if (typeof c === 'string' && c) map.set(d.id, c);
    }
    scanned += snap.size;
    last = snap.docs[snap.docs.length - 1];
    process.stdout.write(`\r  postboxes scanned=${scanned} with-county=${map.size} ${(((Date.now() - start) / 1000).toFixed(0))}s`);
    if (snap.size < POSTBOX_PAGE_SIZE) break;
  }
  process.stdout.write('\n');
  return map;
}

async function main() {
  const opts = parseArgs(process.argv);
  admin.initializeApp({ projectId: opts.projectId });
  const db = admin.firestore();

  console.log('Loading postbox → county map…');
  const postboxCounty = await loadPostboxCounties(db);

  console.log('Aggregating claims…');
  // perUserCounty[uid][county] = { uniqueKeys: Set<postboxKey>, totalPoints: number }
  const perUserCounty = new Map();
  let claimCursor = null;
  let claimsScanned = 0;
  let claimsAttributed = 0;
  const tStart = Date.now();
  while (true) {
    let q = db.collection('claims')
      .orderBy(admin.firestore.FieldPath.documentId())
      .limit(CLAIM_PAGE_SIZE);
    if (claimCursor) q = q.startAfter(claimCursor);
    const snap = await q.get();
    if (snap.empty) break;
    for (const d of snap.docs) {
      claimsScanned++;
      const data = d.data();
      const uid = data.userid;
      const path = data.postboxes;
      const points = (typeof data.points === 'number') ? data.points : 0;
      if (!uid || typeof path !== 'string') continue;
      const key = path.replace(/^\/postbox\//, '');
      const county = postboxCounty.get(key);
      if (!county) continue;

      let userMap = perUserCounty.get(uid);
      if (!userMap) { userMap = new Map(); perUserCounty.set(uid, userMap); }
      let bucket = userMap.get(county);
      if (!bucket) { bucket = { uniqueKeys: new Set(), totalPoints: 0 }; userMap.set(county, bucket); }
      bucket.uniqueKeys.add(key);
      bucket.totalPoints += points;
      claimsAttributed++;
    }
    claimCursor = snap.docs[snap.docs.length - 1];
    process.stdout.write(`\r  claims scanned=${claimsScanned} attributed=${claimsAttributed} ${(((Date.now() - tStart) / 1000).toFixed(0))}s`);
    if (snap.size < CLAIM_PAGE_SIZE) break;
  }
  process.stdout.write('\n');

  // Reshape into per-county leader lists.
  // perCounty[county] = Array<{ uid, uniquePostboxesClaimed, totalPoints }>
  const perCounty = new Map();
  for (const [uid, userMap] of perUserCounty) {
    for (const [county, bucket] of userMap) {
      let arr = perCounty.get(county);
      if (!arr) { arr = []; perCounty.set(county, arr); }
      arr.push({
        uid,
        uniquePostboxesClaimed: bucket.uniqueKeys.size,
        totalPoints: bucket.totalPoints,
      });
    }
  }

  // Filter to a single county if requested.
  let countiesToWrite = Array.from(perCounty.keys());
  if (opts.countySlug) {
    countiesToWrite = countiesToWrite.filter((c) => slug(c) === opts.countySlug);
    if (countiesToWrite.length === 0) {
      console.error(`No county matched slug "${opts.countySlug}".`);
      process.exit(1);
    }
  }

  console.log(`Counties with activity: ${perCounty.size} (writing ${countiesToWrite.length})`);

  // Resolve displayNames for everyone in scope (one read per uid).
  const uidsToResolve = new Set();
  for (const c of countiesToWrite) {
    for (const e of perCounty.get(c)) uidsToResolve.add(e.uid);
  }
  console.log(`Resolving ${uidsToResolve.size} displayNames…`);
  const displayNames = new Map();
  const uidArr = Array.from(uidsToResolve);
  const userRefs = uidArr.map((u) => db.collection('users').doc(u));
  // Batch via getAll in chunks of 100 to stay within Firestore limits.
  for (let i = 0; i < userRefs.length; i += 100) {
    const chunk = userRefs.slice(i, i + 100);
    const docs = await db.getAll(...chunk);
    for (const d of docs) {
      const name = (d.data() ?? {}).displayName;
      displayNames.set(d.id, (typeof name === 'string' && name) ? name : `Player_${d.id.slice(0, 6)}`);
    }
  }

  // Write per-user countyStats and per-county leaderboard docs.
  let pendingBatch = db.batch();
  let pendingCount = 0;
  const flush = async () => {
    if (pendingCount === 0) return;
    if (!opts.dryRun) await pendingBatch.commit();
    pendingBatch = db.batch();
    pendingCount = 0;
  };
  const enqueue = async (ref, data, opt) => {
    pendingBatch.set(ref, data, opt || {});
    pendingCount++;
    if (pendingCount >= BATCH_SIZE) await flush();
  };

  let statsWritten = 0;
  let lbWritten = 0;
  for (const county of countiesToWrite) {
    const cSlug = slug(county);
    if (!cSlug) continue;
    const entries = perCounty.get(county)
      .map((e) => ({
        uid: e.uid,
        displayName: displayNames.get(e.uid) ?? `Player_${e.uid.slice(0, 6)}`,
        uniquePostboxesClaimed: e.uniquePostboxesClaimed,
        totalPoints: e.totalPoints,
      }))
      .sort((a, b) => b.uniquePostboxesClaimed !== a.uniquePostboxesClaimed
        ? b.uniquePostboxesClaimed - a.uniquePostboxesClaimed
        : b.totalPoints - a.totalPoints);

    const lbRef = db.collection('leaderboards').doc('lifetime_by_county')
      .collection('counties').doc(cSlug);
    await enqueue(lbRef, {
      county,
      entries: entries.slice(0, ENTRY_LIMIT),
    });
    lbWritten++;

    for (const e of entries) {
      const statsRef = db.collection('users').doc(e.uid)
        .collection('countyStats').doc(cSlug);
      await enqueue(statsRef, {
        county,
        uniquePostboxesClaimed: e.uniquePostboxesClaimed,
        totalPoints: e.totalPoints,
        updatedAt: admin.firestore.Timestamp.now(),
      }, { merge: true });
      statsWritten++;
    }
  }
  await flush();

  console.log(`\nDone. countyStats writes: ${statsWritten}, leaderboard docs: ${lbWritten}.`);
  if (opts.dryRun) console.log('(dry run — no writes performed)');
}

main().catch((err) => {
  console.error('\nBackfill failed:', err.stack || err.message || err);
  process.exit(1);
});
