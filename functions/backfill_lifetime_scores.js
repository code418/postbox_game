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
 *   users/{uid}.dailyPoints             — sum of today's (London) claim points
 *   users/{uid}.weeklyPoints            — sum of this week's (Mon–today, London) claim points
 *   users/{uid}.monthlyPoints           — sum of this month's (1st–today, London) claim points
 *   users/{uid}.{dailyDate,weekStart,monthStart} — period markers used by the
 *                                                  Friends-only leaderboard to
 *                                                  zero out stale totals
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

// ── Date helpers (mirror _dateUtils.ts / _leaderboardUtils.ts) ────────────────

function getTodayLondon() {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/London',
    year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(new Date());
  const y = parts.find(p => p.type === 'year').value;
  const m = parts.find(p => p.type === 'month').value;
  const d = parts.find(p => p.type === 'day').value;
  return `${y}-${m}-${d}`;
}

function getWeekStart(today) {
  const d = new Date(today + 'T00:00:00Z');
  const day = d.getUTCDay();
  const diff = day === 0 ? -6 : 1 - day;
  d.setUTCDate(d.getUTCDate() + diff);
  return d.toISOString().slice(0, 10);
}

function getMonthStart(today) {
  return today.slice(0, 7) + '-01';
}

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
async function aggregateClaims(db, today, weekStart, monthStart) {
  // uid → { uniquePostboxes: Set, points, dailyPoints, weeklyPoints, monthlyPoints }
  const stats = new Map();
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
      const dailyDate = typeof d.dailyDate === 'string' ? d.dailyDate : null;

      if (!uid || !postboxPath) continue;

      if (!stats.has(uid)) {
        stats.set(uid, {
          uniquePostboxes: new Set(),
          points: 0,
          dailyPoints: 0,
          weeklyPoints: 0,
          monthlyPoints: 0,
        });
      }
      const entry = stats.get(uid);
      entry.uniquePostboxes.add(postboxPath);
      entry.points += points;

      // Bucket into period sums. Weekly/monthly are capped at `today` to match
      // the runtime query (claims with a future dailyDate shouldn't count).
      if (dailyDate) {
        if (dailyDate === today) entry.dailyPoints += points;
        if (dailyDate >= weekStart && dailyDate <= today) entry.weeklyPoints += points;
        if (dailyDate >= monthStart && dailyDate <= today) entry.monthlyPoints += points;
      }
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

  const today = getTodayLondon();
  const weekStart = getWeekStart(today);
  const monthStart = getMonthStart(today);
  console.log(`Period bounds: today=${today}, weekStart=${weekStart}, monthStart=${monthStart}\n`);

  // 1. Aggregate all claims into per-user stats.
  const stats = await aggregateClaims(db, today, weekStart, monthStart);

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
    const s = stats.get(uid);
    return {
      uid,
      displayName: displayNames.get(uid) ?? `Player_${uid.slice(0, 6)}`,
      uniquePostboxesClaimed: s.uniquePostboxes.size,
      lifetimePoints: s.points,
      dailyPoints: s.dailyPoints,
      weeklyPoints: s.weeklyPoints,
      monthlyPoints: s.monthlyPoints,
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
    for (const u of chunk) {
      batch.set(
        db.collection('users').doc(u.uid),
        {
          uniquePostboxesClaimed: u.uniquePostboxesClaimed,
          lifetimePoints: u.lifetimePoints,
          dailyPoints: u.dailyPoints,
          weeklyPoints: u.weeklyPoints,
          monthlyPoints: u.monthlyPoints,
          // Markers so the Friends-only leaderboard doesn't zero out these
          // totals on the staleness check (see leaderboard_screen.dart).
          dailyDate: today,
          weekStart,
          monthStart,
        },
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
