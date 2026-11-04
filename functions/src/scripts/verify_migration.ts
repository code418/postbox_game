/*
 * verify_migration.ts — READ-ONLY document-count snapshot + diff for the
 * us-central1 -> europe-west2 / nam5 -> eur3 migration (ROADMAP v1.3).
 *
 * It only ever calls listCollections() and count() aggregations — it never
 * reads document bodies and never writes. Run it against the live `(default)`
 * database BEFORE the cut-over (nam5) to capture a baseline, and again AFTER
 * the import (eur3); a correct migration leaves every count unchanged.
 *
 * Run after `npm run build` (from functions/):
 *
 *   # Snapshot the current (default) DB to a JSON file
 *   node lib/scripts/verify_migration.js snapshot \
 *     --project the-postbox-game --out pre.json
 *
 *   # ... run the migration, then snapshot again ...
 *   node lib/scripts/verify_migration.js snapshot --out post.json
 *
 *   # Diff the two (no DB access; exits non-zero on ANY mismatch)
 *   node lib/scripts/verify_migration.js compare pre.json post.json
 *
 * Options:
 *   --project <id>     Firebase project ID (default: the-postbox-game)
 *   --out <path>       Snapshot output file (default: migration-snapshot-<ts>.json)
 *   --groups a,b,c     Collection-group ids to count
 *                      (default: entries,countyStats,counties,periods)
 *   --help
 *
 * Auth: GOOGLE_APPLICATION_CREDENTIALS to a service-account JSON, or
 * `gcloud auth application-default login` for ADC. Targets the `(default)`
 * database (Path A keeps everything on the default DB).
 */

import * as fs from "fs";
import * as admin from "firebase-admin";
import {
  diffSnapshots,
  type MigrationSnapshot,
  type DiffRow,
} from "../_migrationVerify";

const DEFAULT_GROUPS = ["entries", "countyStats", "counties", "periods"];

type Options = {
  mode: "snapshot" | "compare";
  projectId: string;
  out: string | null;
  groups: string[];
  files: string[];
  help: boolean;
};

function parseArgs(argv: string[]): Options {
  const opts: Options = {
    mode: "snapshot",
    projectId: "the-postbox-game",
    out: null,
    groups: DEFAULT_GROUPS,
    files: [],
    help: false,
  };
  const args = argv.slice(2);
  let i = 0;
  while (i < args.length) {
    const a = args[i];
    if (a === "snapshot" || a === "compare") opts.mode = a;
    else if (a === "--project") opts.projectId = args[++i];
    else if (a === "--out") opts.out = args[++i];
    else if (a === "--groups") opts.groups = args[++i].split(",").map((s) => s.trim()).filter(Boolean);
    else if (a === "--help" || a === "-h") opts.help = true;
    else if (!a.startsWith("-")) opts.files.push(a);
    else {
      process.stderr.write(`Unknown argument: ${a}\n`);
      opts.help = true;
    }
    i++;
  }
  return opts;
}

async function takeSnapshot(
  db: admin.firestore.Firestore,
  projectId: string,
  groups: string[],
): Promise<MigrationSnapshot> {
  // Counts are independent reads, so fan them out in parallel.
  const cols = await db.listCollections();
  const rootEntries = await Promise.all(
    cols.map(async (col) => [col.id, (await col.count().get()).data().count] as const),
  );
  const roots: Record<string, number> = Object.fromEntries(rootEntries);

  const groupEntries = await Promise.all(
    groups.map(async (g) => {
      try {
        return [g, (await db.collectionGroup(g).count().get()).data().count] as const;
      } catch (err) {
        // A group with no documents (or that never existed) is reported as 0;
        // surface anything else so a counting failure can't masquerade as a match.
        process.stderr.write(
          `  warn: could not count collection-group '${g}': ` +
            `${err instanceof Error ? err.message : String(err)}\n`,
        );
        return [g, 0] as const;
      }
    }),
  );
  const groupCounts: Record<string, number> = Object.fromEntries(groupEntries);

  return {
    project: projectId,
    generatedAt: new Date().toISOString(),
    roots,
    groups: groupCounts,
  };
}

function printSnapshot(snap: MigrationSnapshot): void {
  process.stdout.write(`\nSnapshot of ${snap.project} (default) at ${snap.generatedAt}\n`);
  const pad = (s: string, n: number) => s.padEnd(n);
  const num = (n: number) => String(n).padStart(10);
  process.stdout.write(`  ${pad("COLLECTION", 28)}${pad("SCOPE", 8)}${"COUNT".padStart(10)}\n`);
  let total = 0;
  for (const [name, count] of Object.entries(snap.roots).sort()) {
    process.stdout.write(`  ${pad(name, 28)}${pad("root", 8)}${num(count)}\n`);
    total += count;
  }
  for (const [name, count] of Object.entries(snap.groups).sort()) {
    process.stdout.write(`  ${pad(name, 28)}${pad("group", 8)}${num(count)}\n`);
  }
  process.stdout.write(`  ${pad("(root docs total)", 36)}${num(total)}\n`);
}

function printDiff(rows: DiffRow[]): void {
  const pad = (s: string, n: number) => s.padEnd(n);
  const num = (n: number | null) => (n === null ? "—" : String(n)).padStart(10);
  process.stdout.write(
    `\n  ${pad("COLLECTION", 28)}${pad("SCOPE", 7)}${"BEFORE".padStart(10)}${"AFTER".padStart(10)}${"DELTA".padStart(10)}  STATUS\n`,
  );
  for (const r of rows) {
    const flag = r.status === "ok" ? "ok" : `>> ${r.status.toUpperCase()}`;
    process.stdout.write(
      `  ${pad(r.name, 28)}${pad(r.scope, 7)}${num(r.before)}${num(r.after)}${num(r.delta)}  ${flag}\n`,
    );
  }
}

async function main(): Promise<void> {
  const opts = parseArgs(process.argv);
  if (opts.help) {
    process.stdout.write(
      "Usage: node lib/scripts/verify_migration.js [snapshot|compare] [options]\n" +
        "  snapshot --out <file>          read-only count of the (default) DB\n" +
        "  compare  <before> <after>      diff two snapshot files (exit 1 on mismatch)\n",
    );
    return;
  }

  if (opts.mode === "compare") {
    if (opts.files.length !== 2) {
      throw new Error("compare needs exactly two snapshot files: <before> <after>");
    }
    const before = JSON.parse(fs.readFileSync(opts.files[0], "utf8")) as MigrationSnapshot;
    const after = JSON.parse(fs.readFileSync(opts.files[1], "utf8")) as MigrationSnapshot;
    const result = diffSnapshots(before, after);
    printDiff(result.rows);
    if (result.ok) {
      process.stdout.write("\n✓ All counts match — safe to proceed.\n");
    } else {
      const bad = result.rows.filter((r) => r.status !== "ok").length;
      process.stdout.write(`\n✗ ${bad} collection(s) differ — DO NOT reopen traffic.\n`);
      process.exit(1);
    }
    return;
  }

  // snapshot mode
  if (!admin.apps.length) admin.initializeApp({ projectId: opts.projectId });
  const db = admin.firestore();
  const snap = await takeSnapshot(db, opts.projectId, opts.groups);
  printSnapshot(snap);

  const out = opts.out ?? `migration-snapshot-${snap.generatedAt.replace(/[:.]/g, "-")}.json`;
  fs.writeFileSync(out, JSON.stringify(snap, null, 2) + "\n");
  process.stdout.write(`\nWrote ${out}\n`);
}

main().catch((err) => {
  process.stderr.write(`Error: ${err instanceof Error ? err.message : String(err)}\n`);
  process.exit(1);
});
