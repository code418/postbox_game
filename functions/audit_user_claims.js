#!/usr/bin/env node
'use strict';

/**
 * audit_user_claims.js — pull every claim for a given user, compute inter-claim
 * distances and implied travel speeds, and emit a markdown report + CSV + a
 * standalone Leaflet HTML map showing the route.
 *
 * Read-only: never writes to Firestore. Safe to run against production.
 *
 * Usage (run from the functions/ directory so node_modules resolve):
 *
 *   node audit_user_claims.js --uid <userid> --project the-postbox-game [--out-dir ./audit]
 *
 * Authentication:
 *   Set GOOGLE_APPLICATION_CREDENTIALS to a service account JSON path, OR run
 *   `gcloud auth application-default login` for ADC. The script needs read-only
 *   access to Firestore (roles/datastore.viewer equivalent).
 */

const admin = require('firebase-admin');
const geolib = require('geolib');
const fs = require('fs');
const path = require('path');

// Mirrors functions/src/_travelSpeed.ts. Anything above this is what the live
// server rejects; we treat the same value as the IMPOSSIBLE boundary so audit
// verdicts line up with on-server behaviour.
const MAX_METRES_PER_MIN = 1900;
const POSTBOX_BATCH_SIZE = 100;

// Ordered slowest → fastest. classifySpeed picks the first whose ceiling the
// observed m/min satisfies.
const SPEED_CLASSES = [
  { name: 'WALK',        maxMPerMin: 100,      colour: '#2e7d32' }, // ≤6 km/h
  { name: 'RUN',         maxMPerMin: 200,      colour: '#558b2f' }, // ≤12 km/h
  { name: 'BIKE',        maxMPerMin: 400,      colour: '#f9a825' }, // ≤24 km/h
  { name: 'DRIVE_URBAN', maxMPerMin: 1000,     colour: '#ef6c00' }, // ≤60 km/h
  { name: 'DRIVE_RURAL', maxMPerMin: 1900,     colour: '#c62828' }, // ≤114 km/h
  { name: 'IMPOSSIBLE',  maxMPerMin: Infinity, colour: '#6a1b9a' }, // > anti-cheat ceiling
];
const RARE_MONARCHS = new Set(['EVIIIR', 'CIIIR', 'EVIIR', 'VR']);

function classifySpeed(mPerMin) {
  for (const c of SPEED_CLASSES) if (mPerMin <= c.maxMPerMin) return c.name;
  return 'IMPOSSIBLE';
}

function parseArgs(argv) {
  const opts = { uid: null, projectId: null, outDir: '.', help: false };
  const args = argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--uid') opts.uid = args[++i];
    else if (a === '--project') opts.projectId = args[++i];
    else if (a === '--out-dir') opts.outDir = args[++i];
    else if (a === '--help' || a === '-h') opts.help = true;
    else { console.error(`Unknown argument: ${a}`); opts.help = true; }
  }
  return opts;
}

function usage() {
  console.log(`Usage: node audit_user_claims.js --uid <userid> --project <projectId> [--out-dir <dir>]`);
}

function median(arr) {
  if (arr.length === 0) return 0;
  const s = [...arr].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

async function main() {
  const opts = parseArgs(process.argv);
  if (opts.help || !opts.uid || !opts.projectId) {
    usage();
    process.exit(opts.uid && opts.projectId ? 0 : 1);
  }

  admin.initializeApp({ projectId: opts.projectId });
  const db = admin.firestore();

  console.log(`Fetching claims for ${opts.uid}…`);
  const claimsSnap = await db.collection('claims').where('userid', '==', opts.uid).get();
  console.log(`  ${claimsSnap.size} claim documents.`);
  if (claimsSnap.empty) {
    console.log('No claims found. Nothing to audit.');
    return;
  }

  const claims = [];
  for (const doc of claimsSnap.docs) {
    const d = doc.data();
    if (typeof d.postboxes !== 'string') continue;
    if (!d.timestamp || typeof d.timestamp.toDate !== 'function') continue;
    claims.push({
      docId: doc.id,
      postboxId: d.postboxes.replace(/^\/postbox\//, ''),
      ts: d.timestamp.toDate(),
      dailyDate: typeof d.dailyDate === 'string' ? d.dailyDate : '',
      points: typeof d.points === 'number' ? d.points : 0,
      monarch: typeof d.monarch === 'string' ? d.monarch : null,
      userLat: typeof d.userLat === 'number' ? d.userLat : null,
      userLng: typeof d.userLng === 'number' ? d.userLng : null,
      lat: null,
      lng: null,
    });
  }

  const uniqueIds = Array.from(new Set(claims.map((c) => c.postboxId)));
  console.log(`Resolving ${uniqueIds.length} unique postboxes in batches of ${POSTBOX_BATCH_SIZE}…`);
  const postboxMap = {};
  for (let i = 0; i < uniqueIds.length; i += POSTBOX_BATCH_SIZE) {
    const refs = uniqueIds
      .slice(i, i + POSTBOX_BATCH_SIZE)
      .map((id) => db.collection('postbox').doc(id));
    const docs = await db.getAll(...refs);
    for (const doc of docs) {
      if (!doc.exists) continue;
      const data = doc.data();
      const geo = data.geopoint;
      if (!geo) continue;
      // Match _geo.ts getLatLng: admin SDK exposes either {latitude, longitude}
      // (GeoPoint instance) or the {_latitude, _longitude} raw shape.
      const lat = geo.latitude !== undefined ? geo.latitude : geo._latitude;
      const lng = geo.longitude !== undefined ? geo.longitude : geo._longitude;
      if (typeof lat !== 'number' || typeof lng !== 'number') continue;
      postboxMap[doc.id] = {
        lat,
        lng,
        monarch: data.monarch,
        reference: data.reference,
        county: data.county,
      };
    }
  }

  let missingPostboxes = 0;
  for (const c of claims) {
    const pb = postboxMap[c.postboxId];
    if (!pb) {
      missingPostboxes++;
      continue;
    }
    c.lat = pb.lat;
    c.lng = pb.lng;
    c.reference = pb.reference;
    c.county = pb.county;
    if (!c.monarch && pb.monarch) c.monarch = pb.monarch;
  }
  if (missingPostboxes > 0) {
    console.log(`  ${missingPostboxes} claim(s) reference postbox docs that no longer exist.`);
  }

  claims.sort((a, b) => a.ts - b.ts);

  // Pairwise deltas
  for (let i = 0; i < claims.length; i++) {
    const c = claims[i];
    if (i === 0) {
      c.deltaSec = null;
      c.deltaM = null;
      c.speedMPerMin = null;
      c.classification = 'FIRST';
      c.locSource = 'n/a';
      continue;
    }
    const prev = claims[i - 1];
    c.deltaSec = Math.max(0, (c.ts - prev.ts) / 1000);

    let from = null;
    let to = null;
    let locSource = null;
    if (prev.userLat !== null && prev.userLng !== null && c.userLat !== null && c.userLng !== null) {
      from = { latitude: prev.userLat, longitude: prev.userLng };
      to = { latitude: c.userLat, longitude: c.userLng };
      locSource = 'user_gps';
    } else if (prev.lat !== null && c.lat !== null) {
      from = { latitude: prev.lat, longitude: prev.lng };
      to = { latitude: c.lat, longitude: c.lng };
      locSource = 'postbox';
    } else {
      c.deltaM = null;
      c.speedMPerMin = null;
      c.classification = 'UNKNOWN';
      c.locSource = 'missing';
      continue;
    }
    c.deltaM = geolib.getDistance(from, to);
    // Match the server's floor-at-1-second behaviour from _travelSpeed.ts.
    const effectiveSec = Math.max(c.deltaSec, 1);
    c.speedMPerMin = (c.deltaM / effectiveSec) * 60;
    c.classification = classifySpeed(c.speedMPerMin);
    c.locSource = locSource;
  }

  // Per-day aggregates (group by London-time dailyDate, not the UTC instant)
  const byDay = new Map();
  for (const c of claims) {
    const k = c.dailyDate || c.ts.toISOString().slice(0, 10);
    if (!byDay.has(k)) byDay.set(k, []);
    byDay.get(k).push(c);
  }
  const dayRows = [];
  for (const [date, dayClaims] of Array.from(byDay.entries()).sort()) {
    const count = dayClaims.length;
    const points = dayClaims.reduce((s, c) => s + c.points, 0);
    const monarchs = {};
    for (const c of dayClaims) {
      const key = c.monarch || '∅';
      monarchs[key] = (monarchs[key] || 0) + 1;
    }
    const coords = dayClaims.filter((c) => c.lat !== null);
    let spreadKm = 0;
    if (coords.length >= 2) {
      const lats = coords.map((c) => c.lat);
      const lngs = coords.map((c) => c.lng);
      spreadKm =
        geolib.getDistance(
          { latitude: Math.min(...lats), longitude: Math.min(...lngs) },
          { latitude: Math.max(...lats), longitude: Math.max(...lngs) },
        ) / 1000;
    }
    // Active minutes: 60 s per claim (search + quiz) plus the inter-claim gaps
    // that fit inside a single session (≤30 min between consecutive claims).
    // Long idle gaps between sessions are excluded.
    let activeSec = 60 * count;
    for (let i = 1; i < dayClaims.length; i++) {
      const dt = (dayClaims[i].ts - dayClaims[i - 1].ts) / 1000;
      if (dt <= 1800) activeSec += dt;
    }
    const activeMin = activeSec / 60;
    const classCounts = {};
    let peakClass = null;
    let peakRank = -1;
    for (const c of dayClaims) {
      if (c.classification === 'FIRST' || c.classification === 'UNKNOWN') continue;
      classCounts[c.classification] = (classCounts[c.classification] || 0) + 1;
      const rank = SPEED_CLASSES.findIndex((sc) => sc.name === c.classification);
      if (rank > peakRank) {
        peakRank = rank;
        peakClass = c.classification;
      }
    }
    const intraDayHops = dayClaims.slice(1).filter((c) => c.deltaM !== null);
    const totalDistM = intraDayHops.reduce((s, c) => s + c.deltaM, 0);
    const totalSec = intraDayHops.reduce((s, c) => s + c.deltaSec, 0);
    const avgKmH = totalSec > 0 ? (totalDistM / totalSec) * 3.6 : 0;
    const peakKmH = intraDayHops.length
      ? Math.max(...intraDayHops.map((c) => (c.speedMPerMin * 60) / 1000))
      : 0;

    let verdict;
    if (count <= 1) verdict = 'Single claim — no inter-claim test.';
    else if (peakKmH > 114) verdict = `IMPOSSIBLE: peak ${peakKmH.toFixed(0)} km/h exceeds anti-cheat ceiling.`;
    else if (peakKmH > 60) verdict = `Plausible only by car (peak ${peakKmH.toFixed(0)} km/h, avg ${avgKmH.toFixed(0)} km/h).`;
    else if (peakKmH > 24) verdict = `Plausible by car or e-bike (peak ${peakKmH.toFixed(0)} km/h, avg ${avgKmH.toFixed(0)} km/h).`;
    else if (peakKmH > 12) verdict = `Plausible by bicycle (peak ${peakKmH.toFixed(0)} km/h).`;
    else if (peakKmH > 6) verdict = `Plausible at running pace (peak ${peakKmH.toFixed(0)} km/h).`;
    else verdict = `Plausible on foot (peak ${peakKmH.toFixed(1)} km/h).`;

    const rareCount = dayClaims.filter((c) => RARE_MONARCHS.has(c.monarch)).length;
    const highSpeedHops =
      (classCounts.IMPOSSIBLE || 0) * 5 +
      (classCounts.DRIVE_RURAL || 0) * 2 +
      (classCounts.DRIVE_URBAN || 0);
    const spreadVsTime = activeMin > 0 ? (spreadKm / activeMin) * 60 : 0; // implied km/h from spread
    const suspicion =
      highSpeedHops * 3 + rareCount + Math.max(0, spreadVsTime - 20) * 0.5 + count * 0.1;

    dayRows.push({
      date,
      count,
      points,
      monarchs,
      spreadKm,
      activeMin,
      peakKmH,
      avgKmH,
      peakClass,
      classCounts,
      verdict,
      suspicion,
      claims: dayClaims,
    });
  }

  const datestamp = new Date().toISOString().slice(0, 10).replace(/-/g, '');
  const baseName = `audit_${opts.uid}_${datestamp}`;
  const outDir = path.resolve(opts.outDir);
  if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });

  // CSV
  const csvLines = [
    'timestamp_iso,dailyDate,postboxId,lat,lng,monarch,points,prev_dist_m,prev_elapsed_s,speed_m_per_min,classification,location_source',
  ];
  for (const c of claims) {
    csvLines.push(
      [
        c.ts.toISOString(),
        c.dailyDate,
        c.postboxId,
        c.lat !== null ? c.lat : '',
        c.lng !== null ? c.lng : '',
        c.monarch || '',
        c.points,
        c.deltaM !== null ? c.deltaM : '',
        c.deltaSec !== null ? c.deltaSec.toFixed(0) : '',
        c.speedMPerMin !== null ? c.speedMPerMin.toFixed(1) : '',
        c.classification,
        c.locSource,
      ].join(','),
    );
  }
  const csvPath = path.join(outDir, baseName + '.csv');
  fs.writeFileSync(csvPath, csvLines.join('\n'));

  // Markdown
  const mdPath = path.join(outDir, baseName + '.md');
  fs.writeFileSync(mdPath, renderMarkdown(opts.uid, claims, dayRows, missingPostboxes));

  // HTML map
  const htmlPath = path.join(outDir, baseName + '.html');
  fs.writeFileSync(htmlPath, renderHtml(opts.uid, claims, dayRows));

  console.log('');
  console.log(`Report:  ${mdPath}`);
  console.log(`CSV:     ${csvPath}`);
  console.log(`Map:     ${htmlPath}`);
  console.log('');
  console.log(`Open the HTML file in a browser to inspect the route geographically.`);
}

function renderMarkdown(uid, claims, dayRows, missingPostboxes) {
  const totalClaims = claims.length;
  const totalPoints = claims.reduce((s, c) => s + c.points, 0);
  const daysActive = dayRows.length;
  const peakDay = dayRows.reduce(
    (best, r) => (best === null || r.points > best.points ? r : best),
    null,
  );
  const impossibleHops = claims.filter((c) => c.classification === 'IMPOSSIBLE').length;
  const driveRuralHops = claims.filter((c) => c.classification === 'DRIVE_RURAL').length;
  const driveUrbanHops = claims.filter((c) => c.classification === 'DRIVE_URBAN').length;
  const firstDate = claims[0] ? claims[0].dailyDate : '—';
  const lastDate = claims[claims.length - 1] ? claims[claims.length - 1].dailyDate : '—';

  const lines = [];
  lines.push(`# Claim audit — \`${uid}\``);
  lines.push('');
  lines.push(`**Period:** ${firstDate} → ${lastDate}`);
  lines.push(`**Total claims:** ${totalClaims}`);
  lines.push(`**Total points:** ${totalPoints}`);
  lines.push(`**Days active:** ${daysActive}`);
  if (peakDay) {
    lines.push(`**Peak day:** ${peakDay.date} (${peakDay.points} pts, ${peakDay.count} claims)`);
  }
  lines.push(
    `**Inter-claim hops flagged:** ${impossibleHops} impossible, ${driveRuralHops} highway-speed, ${driveUrbanHops} urban-driving.`,
  );
  if (missingPostboxes > 0) {
    lines.push(
      `> Note: ${missingPostboxes} claim(s) reference postbox docs that no longer exist; those hops fall back to the user-GPS pair recorded at claim time, or are marked \`UNKNOWN\` if neither source resolves.`,
    );
  }
  lines.push('');
  lines.push('## Per-day summary');
  lines.push('');
  lines.push(
    '| Date | Claims | Points | Spread (km) | Active (min) | Avg km/h | Peak km/h | Verdict |',
  );
  lines.push(
    '|------|-------:|-------:|------------:|-------------:|---------:|----------:|---------|',
  );
  for (const r of dayRows) {
    lines.push(
      `| ${r.date} | ${r.count} | ${r.points} | ${r.spreadKm.toFixed(2)} | ${r.activeMin.toFixed(0)} | ${r.avgKmH.toFixed(1)} | ${r.peakKmH.toFixed(1)} | ${r.verdict} |`,
    );
  }
  lines.push('');

  const top = [...dayRows].sort((a, b) => b.suspicion - a.suspicion).slice(0, 5);
  lines.push('## Top 5 most suspicious days');
  lines.push('');
  lines.push(
    'Suspicion score weights `IMPOSSIBLE`/highway-speed hops, rare cyphers (EVIIIR/CIIIR/EVIIR/VR), and geographic spread per active minute. Higher = more worth investigating.',
  );
  lines.push('');
  for (const r of top) {
    lines.push(`### ${r.date} — ${r.count} claims, ${r.points} pts, suspicion ${r.suspicion.toFixed(1)}`);
    lines.push(
      `Spread ${r.spreadKm.toFixed(2)} km · active ${r.activeMin.toFixed(0)} min · avg ${r.avgKmH.toFixed(1)} km/h · peak ${r.peakKmH.toFixed(1)} km/h`,
    );
    const monarchSummary = Object.entries(r.monarchs)
      .sort((a, b) => b[1] - a[1])
      .map(([k, v]) => `${k}×${v}`)
      .join(', ');
    lines.push(`Cyphers: ${monarchSummary}`);
    lines.push(`Verdict: ${r.verdict}`);
    lines.push('');
    lines.push('| Time | Postbox | Monarch | Pts | Δ min | Δ m | Speed (km/h) | Class | Loc src |');
    lines.push('|------|---------|---------|----:|------:|----:|-------------:|-------|---------|');
    for (const c of r.claims) {
      const tt = c.ts.toISOString().slice(11, 19);
      const dmin = c.deltaSec !== null ? (c.deltaSec / 60).toFixed(1) : '—';
      const dm = c.deltaM !== null ? c.deltaM.toFixed(0) : '—';
      const sp = c.speedMPerMin !== null ? ((c.speedMPerMin * 60) / 1000).toFixed(1) : '—';
      lines.push(
        `| ${tt} | ${c.postboxId} | ${c.monarch || '—'} | ${c.points} | ${dmin} | ${dm} | ${sp} | ${c.classification} | ${c.locSource} |`,
      );
    }
    lines.push('');
  }

  lines.push('## Overall assessment');
  lines.push('');
  const movingDays = dayRows.filter((r) => r.count > 1);
  const medianAvgKmH = median(movingDays.map((r) => r.avgKmH));
  const medianPeakKmH = median(movingDays.map((r) => r.peakKmH));
  const carDays = dayRows.filter((r) => r.peakKmH > 24).length;
  const footDays = dayRows.filter((r) => r.peakKmH > 0 && r.peakKmH <= 12).length;
  lines.push(
    `Across ${dayRows.length} active days, median inter-claim peak speed is **${medianPeakKmH.toFixed(1)} km/h** and median average is **${medianAvgKmH.toFixed(1)} km/h**. ${carDays} day(s) show peak speeds in driving territory (>24 km/h); ${footDays} day(s) are foot-pace (≤12 km/h).`,
  );
  lines.push('');
  if (impossibleHops > 0) {
    lines.push(
      `⚠️ **${impossibleHops} hop(s) imply impossible speeds** (>${MAX_METRES_PER_MIN} m/min ≈ 114 km/h). These should have been rejected by the live anti-cheat check. Likely causes: claims predate the check, legacy claims missing \`userLat\`/\`userLng\` (so the check fell open), or a bug in the check itself. Worth investigating.`,
    );
  } else if (driveRuralHops > 0) {
    lines.push(
      `Pattern is consistent with **driving** between postboxes (${driveRuralHops} highway-speed hop(s) in the 60–114 km/h band, plus ${driveUrbanHops} urban-driving hop(s)). Not against any current rule, but worth checking whether the user is also achieving rare cyphers across wide geography in tight time windows.`,
    );
  } else if (medianPeakKmH > 24) {
    lines.push(
      `Pattern is consistent with **vehicle-based play** (median peak ${medianPeakKmH.toFixed(0)} km/h). The high score appears to come from covering a lot of ground per session — physically possible by car or e-bike, not on foot.`,
    );
  } else if (medianPeakKmH > 12) {
    lines.push(
      `Pattern is consistent with **cycling**. The high score comes from a wide route covered at bike pace, not from impossible speeds.`,
    );
  } else {
    lines.push(
      `Pattern is consistent with **foot or slow-cycle play**. The high score is driven by breadth and consistency rather than improbable speeds.`,
    );
  }
  lines.push('');
  lines.push(
    `*Generated ${new Date().toISOString()}. Speed thresholds: WALK ≤6 km/h, RUN ≤12 km/h, BIKE ≤24 km/h, DRIVE_URBAN ≤60 km/h, DRIVE_RURAL ≤114 km/h (matches the live \`_travelSpeed.ts\` ceiling), IMPOSSIBLE >114 km/h.*`,
  );

  return lines.join('\n');
}

function renderHtml(uid, claims, dayRows) {
  const claimData = claims
    .filter((c) => c.lat !== null)
    .map((c, i) => ({
      n: i + 1,
      ts: c.ts.toISOString(),
      date: c.dailyDate,
      lat: c.lat,
      lng: c.lng,
      postboxId: c.postboxId,
      monarch: c.monarch || '—',
      points: c.points,
      speedKmH: c.speedMPerMin !== null ? (c.speedMPerMin * 60) / 1000 : null,
      deltaMin: c.deltaSec !== null ? c.deltaSec / 60 : null,
      deltaM: c.deltaM,
      cls: c.classification,
    }));
  const classColours = Object.fromEntries(SPEED_CLASSES.map((s) => [s.name, s.colour]));
  classColours.FIRST = '#9e9e9e';
  classColours.UNKNOWN = '#9e9e9e';

  const distinctDates = Array.from(new Set(claimData.map((c) => c.date)))
    .filter(Boolean)
    .sort();

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Claim audit — ${uid}</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<style>
  body { margin: 0; font-family: system-ui, -apple-system, sans-serif; }
  #header { padding: 8px 12px; background: #fff; border-bottom: 1px solid #ddd; display: flex; gap: 16px; align-items: center; flex-wrap: wrap; }
  #header h1 { font-size: 14px; margin: 0; font-family: monospace; }
  #map { height: calc(100vh - 50px); }
  .pin {
    background: #c8102e; color: white; border-radius: 50%;
    width: 24px; height: 24px; line-height: 22px; text-align: center;
    font-size: 11px; font-weight: bold; border: 2px solid white;
    box-shadow: 0 0 4px rgba(0,0,0,0.4);
  }
  .legend {
    background: white; padding: 8px 10px; border-radius: 4px; font-size: 12px;
    line-height: 1.7; box-shadow: 0 0 4px rgba(0,0,0,0.2);
  }
  .legend .swatch { display: inline-block; width: 18px; height: 4px; vertical-align: middle; margin-right: 6px; }
  .leaflet-popup-content b { font-family: monospace; }
</style>
</head>
<body>
<div id="header">
  <h1>Claim audit — ${uid}</h1>
  <label>Day:
    <select id="dayFilter">
      <option value="">All days (${claimData.length} claims)</option>
      ${distinctDates.map((d) => `<option value="${d}">${d}</option>`).join('')}
    </select>
  </label>
  <span id="dayStats"></span>
</div>
<div id="map"></div>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script>
const CLAIMS = ${JSON.stringify(claimData)};
const CLASS_COLOUR = ${JSON.stringify(classColours)};

const map = L.map('map');
L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
  attribution: '© OpenStreetMap', maxZoom: 19
}).addTo(map);

const layer = L.layerGroup().addTo(map);
const dayFilter = document.getElementById('dayFilter');
const dayStats = document.getElementById('dayStats');

function render(selectedDate) {
  layer.clearLayers();
  const subset = selectedDate ? CLAIMS.filter(c => c.date === selectedDate) : CLAIMS;
  if (subset.length === 0) { dayStats.textContent = 'No claims with coords for this day.'; return; }

  for (let i = 1; i < subset.length; i++) {
    const a = subset[i-1], b = subset[i];
    const colour = CLASS_COLOUR[b.cls] || '#9e9e9e';
    L.polyline([[a.lat, a.lng], [b.lat, b.lng]], { color: colour, weight: 3, opacity: 0.75 }).addTo(layer);
  }

  for (const c of subset) {
    const icon = L.divIcon({
      className: '', html: '<div class="pin">' + c.n + '</div>',
      iconSize: [24, 24], iconAnchor: [12, 12]
    });
    const speedLine = c.speedKmH !== null
      ? 'Arrived at ' + c.speedKmH.toFixed(1) + ' km/h after ' + c.deltaMin.toFixed(1) + ' min / ' + c.deltaM + ' m (' + c.cls + ')'
      : 'First claim of the run';
    const popup = '<b>' + c.postboxId + '</b><br>' +
                  c.date + ' ' + c.ts.slice(11, 19) + 'Z<br>' +
                  'Monarch: ' + c.monarch + ' · ' + c.points + ' pts<br>' +
                  speedLine;
    L.marker([c.lat, c.lng], { icon }).bindPopup(popup).addTo(layer);
  }

  const bounds = L.latLngBounds(subset.map(c => [c.lat, c.lng]));
  map.fitBounds(bounds, { padding: [30, 30], maxZoom: 16 });

  const pts = subset.reduce((s, c) => s + c.points, 0);
  dayStats.textContent = subset.length + ' claims · ' + pts + ' pts';
}

dayFilter.addEventListener('change', e => render(e.target.value));
render('');

const legend = L.control({ position: 'bottomright' });
legend.onAdd = () => {
  const div = L.DomUtil.create('div', 'legend');
  div.innerHTML = '<b>Inter-claim speed</b><br>' +
    ${JSON.stringify(SPEED_CLASSES.map((s) => ({ name: s.name, colour: s.colour })))}.map(s =>
      '<span class="swatch" style="background:' + s.colour + '"></span>' + s.name
    ).join('<br>');
  return div;
};
legend.addTo(map);
</script>
</body>
</html>`;
}

main().catch((err) => {
  console.error(err && err.stack ? err.stack : err);
  process.exit(1);
});
