// Accept/reject decision rules for one report. Pure, so they can be unit
// tested: defaults, what goes over the wire, and what blocks a confirm.

import type { DuplicateFlagDto, ReportSummaryDto, ReviewRequestDto } from "../../functions/src/_reviewTypes";
import type { DecisionMode } from "./keys.ts";

export type CypherChoice = { kind: "key"; key: string } | { kind: "plain" } | { kind: "unsure" };

export interface DecisionState {
  mode: DecisionMode;
  cypher: CypherChoice;
  reference: string;
  note: string;
}

/**
 * The cypher an accept starts from: the reporter's suggestion (null = plain).
 * With no suggestion it's "unsure". For a cypher report that forces an
 * explicit pick: accepting the current cypher would be a no-op correction.
 */
export function defaultCypher(r: ReportSummaryDto): CypherChoice {
  if (r.hasSuggestedMonarch) return r.suggestedMonarch === null ? { kind: "plain" } : { kind: "key", key: r.suggestedMonarch };
  return { kind: "unsure" };
}

export function initialDecision(r: ReportSummaryDto): DecisionState {
  return { mode: "idle", cypher: defaultCypher(r), reference: r.suggestedReference ?? "", note: "" };
}

/**
 * "Not sure" is only a real choice for a missing postbox with no suggestion.
 * Leaving finalMonarch out makes the server fall back to the reporter's
 * suggestion, so where there is one, "not sure" would silently mean "theirs".
 */
export function unsureAllowed(r: ReportSummaryDto): boolean {
  return r.type === "missing_postbox" && !r.hasSuggestedMonarch;
}

/** finalMonarch on the wire: a key, null for plain, undefined to omit. */
export function wireMonarch(c: CypherChoice): string | null | undefined {
  if (c.kind === "key") return c.key;
  if (c.kind === "plain") return null;
  return undefined;
}

/** The impact query value, or null when there's nothing to preview. */
export function impactParam(c: CypherChoice): string | null {
  if (c.kind === "key") return c.key;
  if (c.kind === "plain") return "plain";
  return null;
}

export function sameChoice(a: CypherChoice, b: CypherChoice): boolean {
  return a.kind === b.kind && (a.kind !== "key" || (b.kind === "key" && a.key === b.key));
}

export function buildReviewRequest(d: DecisionState): ReviewRequestDto {
  const note = d.note.trim();
  if (d.mode === "reject") return { decision: "reject", ...(note ? { reviewNote: note } : {}) };
  const finalMonarch = wireMonarch(d.cypher);
  return {
    decision: "accept",
    ...(finalMonarch !== undefined ? { finalMonarch } : {}),
    // Always explicit: "" means "no reference", not "use the suggestion".
    finalReference: d.reference.trim(),
    ...(note ? { reviewNote: note } : {}),
  };
}

export interface ConfirmContext {
  report: ReportSummaryDto;
  decision: DecisionState;
  /** The impact preview for the chosen cypher has loaded (cypher reports). */
  impactReady: boolean;
  flags: ReadonlyArray<DuplicateFlagDto>;
  override: boolean;
  noteMax: number;
  referenceMax: number;
  writesBlocked: boolean;
}

/** Why a confirm can't go ahead yet, or null when it can. */
export function confirmBlocker(c: ConfirmContext): string | null {
  const d = c.decision;
  if (d.mode === "idle") return "Choose accept (a) or reject (r) first.";
  if (c.writesBlocked) return "Maintenance mode is on, so reviews are paused.";
  if (d.note.trim().length > c.noteMax) return `Keep the note to ${c.noteMax} characters.`;
  if (d.mode === "reject") return null;
  if (d.reference.trim().length > c.referenceMax) return `Keep the reference to ${c.referenceMax} characters.`;
  if (c.report.type === "wrong_cypher") {
    if (d.cypher.kind === "unsure") return "Pick the cypher first: 1 to 9, or 0 for plain.";
    if (!c.impactReady) return "Wait for the impact preview to load.";
  }
  if (d.cypher.kind === "unsure" && !unsureAllowed(c.report)) return "Pick the cypher first: 1 to 9, or 0 for plain.";
  if (!c.override && c.flags.some((f) => f.severity === "high")) {
    return "This looks like a duplicate. Press Shift+Enter to accept anyway.";
  }
  return null;
}
