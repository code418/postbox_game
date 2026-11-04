#!/usr/bin/env node
'use strict';

/**
 * set_admin.js — grant or revoke the `admin` custom claim on a Firebase Auth user.
 *
 * The in-app admin review interface (lib/admin/) and the reviewReport Cloud
 * Function gate on `request.auth.token.admin === true`. Use this script to
 * bootstrap the first admin (and to add/remove others later).
 *
 * Usage (run from the functions/ directory so node_modules are resolvable):
 *
 *   node set_admin.js <uid> [options]
 *
 * Options:
 *   --project <projectId>   Firebase project ID (default: the-postbox-game)
 *   --remove                Revoke admin instead of granting it
 *   --help                  Show this help
 *
 * Authentication:
 *   Set GOOGLE_APPLICATION_CREDENTIALS to a service account JSON path, OR run
 *   `gcloud auth application-default login` for ADC.
 *
 * Examples:
 *   cd functions
 *   node set_admin.js abc123uid --project the-postbox-game
 *   node set_admin.js abc123uid --remove
 *
 * Note: the user must sign out and back in (or call getIdToken(true)) for the
 * new claim to take effect on the client.
 */

const admin = require('firebase-admin');

function parseArgs(argv) {
  const opts = { uid: null, projectId: 'the-postbox-game', remove: false };
  const args = argv.slice(2);
  let i = 0;
  while (i < args.length) {
    const a = args[i];
    if (a === '--project') { opts.projectId = args[++i]; }
    else if (a === '--remove') { opts.remove = true; }
    else if (a === '--help' || a === '-h') { opts.help = true; }
    else if (!a.startsWith('-') && opts.uid === null) { opts.uid = a; }
    else { console.error(`Unknown argument: ${a}`); opts.help = true; }
    i++;
  }
  return opts;
}

function usage() {
  console.log(`Usage: node set_admin.js <uid> [--project <projectId>] [--remove]`);
}

async function main() {
  const opts = parseArgs(process.argv);
  if (opts.help || !opts.uid) { usage(); process.exit(opts.uid ? 0 : 1); }

  admin.initializeApp({ projectId: opts.projectId });

  const user = await admin.auth().getUser(opts.uid);
  const existing = user.customClaims || {};
  const next = { ...existing };
  if (opts.remove) delete next.admin;
  else next.admin = true;

  await admin.auth().setCustomUserClaims(opts.uid, next);
  console.log(`${opts.remove ? 'Revoked' : 'Granted'} admin for ${opts.uid} (${user.email || user.displayName || 'no email'}).`);
  console.log('The user must re-authenticate (sign out/in or getIdToken(true)) for this to take effect.');
}

main().catch((err) => {
  console.error(err && err.message ? err.message : err);
  process.exit(1);
});
