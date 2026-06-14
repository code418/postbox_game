/*
 * _migrationVerify.ts — pure helpers for the read-only Firestore migration
 * verification CLI (scripts/verify_migration.ts).
 *
 * Kept separate from the CLI (and free of any firebase-admin / I/O) so the
 * diff verdict — the part where a silent bug would falsely report "match" and
 * let traffic reopen on incomplete data — is unit-testable. See the
 * `diffSnapshots` tests in test/test.index.ts.
 */

/** A point-in-time document-count snapshot of the `(default)` database. */
export interface MigrationSnapshot {
  project: string;
  /** ISO-8601 timestamp the snapshot was taken. */
  generatedAt: string;
  /** Root collection name -> document count. */
  roots: Record<string, number>;
  /** Collection-group id -> document count (across all nesting depths). */
  groups: Record<string, number>;
}

export type DiffScope = "root" | "group";
export type DiffStatus = "ok" | "mismatch" | "missing";

export interface DiffRow {
  name: string;
  scope: DiffScope;
  /** Count in the "before" snapshot, or null if the key is absent there. */
  before: number | null;
  /** Count in the "after" snapshot, or null if the key is absent there. */
  after: number | null;
  /** (after ?? 0) - (before ?? 0). */
  delta: number;
  status: DiffStatus;
}

export interface DiffResult {
  /** True only if every row is "ok" (present on both sides, equal counts). */
  ok: boolean;
  rows: DiffRow[];
}

function diffSection(
  scope: DiffScope,
  before: Record<string, number>,
  after: Record<string, number>,
): DiffRow[] {
  const names = Array.from(
    new Set([...Object.keys(before), ...Object.keys(after)]),
  ).sort();

  return names.map((name) => {
    const b = Object.prototype.hasOwnProperty.call(before, name)
      ? before[name]
      : null;
    const a = Object.prototype.hasOwnProperty.call(after, name)
      ? after[name]
      : null;
    const delta = (a ?? 0) - (b ?? 0);
    const status: DiffStatus =
      b === null || a === null ? "missing" : a === b ? "ok" : "mismatch";
    return { name, scope, before: b, after: a, delta, status };
  });
}

/**
 * Compares two snapshots and returns a per-collection diff. A correct
 * migration leaves every count unchanged, so any non-"ok" row means the
 * import is incomplete (or grew) and traffic must NOT be reopened.
 */
export function diffSnapshots(
  before: MigrationSnapshot,
  after: MigrationSnapshot,
): DiffResult {
  const rows = [
    ...diffSection("root", before.roots, after.roots),
    ...diffSection("group", before.groups, after.groups),
  ];
  return { ok: rows.every((r) => r.status === "ok"), rows };
}
