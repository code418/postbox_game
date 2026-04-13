#!/usr/bin/env node
'use strict';

/**
 * backfill_lifetime_scores.js — Recompute uniquePostboxesClaimed + lifetimePoints
 *
 * Reads every document in the `claims` collection, aggregates each user's
 * unique postboxes claimed and total points, then writes the correct values to:
 *
 *   users/{uid}.uniquePostboxesClaimed  — count of distinct postboxes ever claimed
 *   users/{uid}.lifetimePoints          — sum of all points across all claims
 *   leaderboards/lifetime               — rebuilt from the computed stats (top 100)
 *
 * This is needed when the Cloud Function's lifetime update failed silently
 * (e.g. the Firestore composite index was missing, causing Promise.all to throw
 * before the users/{uid} set() call was reached).
 *
 * Usage (run from the functions/ directory so node_modules are resolvable):
 *
 *   node backfill_lifetime_scores.js [options]
 *
 * Options:
 *   --project  <projectId>   Firebase project ID (default: the-postbox-game)
 *   --dry-run                Compute and display totals without writing anything
 *   --help                   Show this help
 *
 * Authentication:
 *   Set GOOGLE_APPLICATION_CREDENTIALS to a service account JSON path, OR run
 *   `gcloud auth application-default login` for ADC.
 *
 * Example:
 *   cd functions
 *   node backfill_lifetime_scores.js --project the-postbox-game
 *   node backfill_lifetime_scores.js --dry-run
 */

const admin = require('firebase-admin');

// ── Config ────────────────────────────────────────────────────────────────────

const DEFAULT_PROJECT = 'the-postbox-game';

// Firestore hard limit is 500; stay under it for safety.
const BATCH_SIZE = 400;

// Number of claim docs to fetch per page when scanning.
const PAGE_SIZE = 500;

// Must match the limit in _leaderboardUtils.ts → mergeLifetimeEntries.
const LIFETIME_LIMIT = 100;

// ── Argument parsing ──────────────────────────────────────────────────────────

function parseArgs(argv) {
  const args = argv.slice(2);
  const opts = { projectId: DEFAULT_PROJECT, dryRun: false };

  let i = 0;
  while (i < args.length) {
    const a = args[i];
    if (a === '--project')         { opts.projectId = args[++i]; }
    else if (a === '--dry-run')    { opts.dryRun = true; }
    else if (a === '--help' || a === '-h') { printHelp(); process.exit(0); }
    i++;
  }
  return opts;
}

function printHelp() {
  console.log(`Usage: node backfill_lifetime_scores.js [options]

Scans all claims and recomputes uniquePostboxesClaimed + lifetimePoints for
every user, then writes the results to users/{uid} and leaderboards/lifetime.

Options:
  --project  <projectId>  Firebase project ID (default: ${DEFAULT_PROJECT})
  --dry-run               Compute totals and show a preview without writing
  --help                  Show this help

Authentication:
  Set GOOGLE_APPLICATION_CREDENTIALS=<path/to/serviceAccount.json>
  or run: gcloud auth application-default login

Example:
  cd functions
  node backfill_lifetime_scores.js --project the-postbox-game
  node backfill_lifetime_scores.js --dry-run`);
}

// ── Claims scanner ────────────────────────────────────────────────────────────

/**
 * Streams all documents from the `claims` collection in pages and aggregates
 * per-user stats. Returns a Map<uid, { uniquePostboxes: Set<string>, points: number }>.
 */
async function aggregateClaims(db) {
  const stats = new Map(); // uid → { uniquePostboxes: Set, points: number }
  let lastDoc = null;
  let totalClaims = 0;

  process.stdout.write('Scanning claims');

  while (true) {
    let query = db.collection('claims').orderBy('__name__').limit(PAGE_SIZE);
    if (lastDoc) query = query.startAfter(lastDoc);

    const snap = await query.get();
    if (snap.empty) break;

    for (const doc of snap.docs) {
      const d = doc.data();
      const uid = d.userid;
      const postboxPath = d.postboxes; // e.g. "/postbox/osm_12345"
      const points = typeof d.points === 'number' ? d.points : 0;

      if (!uid || !postboxPath) continue;

      if (!stats.has(uid)) {
        stats.set(uid, { uniquePostboxes: new Set(), points: 0 });
      }
      const entry = stats.get(uid);
      entry.uniquePostboxes.add(postboxPath);
      entry.points += points;
    }

    totalClaims += snap.docs.length;
    lastDoc = snap.docs[snap.docs.length - 1];
    process.stdout.write('.');

    if (snap.docs.length < PAGE_SIZE) break; // last page
  }

  console.log(` done. ${totalClaims.toLocaleString()} claim(s) across ${stats.size.toLocaleString()} user(s).`);
  return stats;
}

// ── Display name lookup ───────────────────────────────────────────────────────

/**
 * Fetches display names for a list of uids. Reads in parallel (up to 50 at
 * a time to avoid overwhelming Firestore). Returns a Map<uid, displayName>.
 */
async function fetchDisplayNames(db, uids) {
  const names = new Map();
  const CONCURRENCY = 50;

  for (let i = 0; i < uids.length; i += CONCURRENCY) {
    const chunk = uids.slice(i, i + CONCURRENCY);
    const docs = await Promise.all(
      chunk.map((uid) => db.collection('users').doc(uid).get())
    );
    for (const doc of docs) {
      const displayName =
        (doc.exists && doc.data()?.displayName) ||
        `Player_${doc.id.slice(0, 6)}`;
      names.set(doc.id, displayName);
    }
  }
  return names;
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main() {
  const opts = parseArgs(process.argv);

  admin.initializeApp({ projectId: opts.projectId });
  const db = admin.firestore();

  console.log(`Project: ${opts.projectId}${opts.dryRun ? '  [DRY RUN — no writes]' : ''}\n`);

  // 1. Aggregate all claims into per-user stats.
  const stats = await aggregateClaims(db);

  if (stats.size === 0) {
    console.log('No claims found. Nothing to backfill.');
    return;
  }

  // 2. Fetch display names for all users with claims.
  const uids = [...stats.keys()];
  process.stdout.write(`Fetching display names for ${uids.length} user(s)…`);
  const displayNames = await fetchDisplayNames(db, uids);
  console.log(' done.');

  // 3. Build the update payload for each user.
  const updates = uids.map((uid) => {
    const { uniquePostboxes, points } = stats.get(uid);
    return {
      uid,
      displayName: displayNames.get(uid) ?? `Player_${uid.slice(0, 6)}`,
      uniquePostboxesClaimed: uniquePostboxes.size,
      lifetimePoints: points,
    };
  });

  // Sort descending for display purposes.
  updates.sort((a, b) =>
    b.uniquePostboxesClaimed !== a.uniquePostboxesClaimed
      ? b.uniquePostboxesClaimed - a.uniquePostboxesClaimed
      : b.lifetimePoints - a.lifetimePoints
  );

  // 4. Preview.
  console.log(`\nTop ${Math.min(10, updates.length)} users by unique postboxes:`);
  for (const u of updates.slice(0, 10)) {
    console.log(
      `  ${u.displayName.padEnd(30)} ${String(u.uniquePostboxesClaimed).padStart(4)} box(es)  ${String(u.lifetimePoints).padStart(6)} pts`
    );
  }

  if (opts.dryRun) {
    console.log('\n[DRY RUN] No writes performed.');
    console.log(`Would update ${updates.length} user document(s) and leaderboards/lifetime.`);
    return;
  }

  // 5. Write updated stats to users/{uid} in batches.
  console.log(`\nWriting ${updates.length} user document(s)…`);
  let written = 0;
  const start = Date.now();

  for (let i = 0; i < updates.length; i += BATCH_SIZE) {
    const chunk = updates.slice(i, i + BATCH_SIZE);
    const batch = db.batch();
    for (const { uid, uniquePostboxesClaimed, lifetimePoints } of chunk) {
      batch.set(
        db.collection('users').doc(uid),
        { uniquePostboxesClaimed, lifetimePoints },
        { merge: true }
      );
    }
    await batch.commit();
    written += chunk.length;
    process.stdout.write(`\r  ${written} / ${updates.length} user(s) written…`);
  }
  console.log(''); // newline after progress

  // 6. Rebuild leaderboards/lifetime from the computed stats.
  console.log('Rebuilding leaderboards/lifetime…');
  const lifetimeEntries = updates
    .filter((u) => u.uniquePostboxesClaimed > 0 || u.lifetimePoints > 0)
    .slice(0, LIFETIME_LIMIT)
    .map(({ uid, displayName, uniquePostboxesClaimed, lifetimePoints }) => ({
      uid,
      displayName,
      uniquePostboxesClaimed,
      totalPoints: lifetimePoints,
    }));

  await db.collection('leaderboards').doc('lifetime').set({
    periodKey: 'lifetime',
    entries: lifetimeEntries,
  });

  const elapsed = ((Date.now() - start) / 1000).toFixed(1);
  console.log(`\nBackfill complete in ${elapsed}s.`);
  console.log(`  users/{uid} updated:          ${written}`);
  console.log(`  leaderboards/lifetime entries: ${lifetimeEntries.length}`);
}

main().catch((err) => {
  console.error('\nBackfill failed:', err.message ?? err);
  process.exit(1);
});
