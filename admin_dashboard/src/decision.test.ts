import { test } from "node:test";
import assert from "node:assert/strict";
import type { ReportSummaryDto } from "../../functions/src/_reviewTypes";
import {
  buildReviewRequest,
  confirmBlocker,
  defaultCypher,
  initialDecision,
  impactParam,
  unsureAllowed,
  type ConfirmContext,
  type DecisionState,
} from "./decision.ts";

const report = (over: Partial<ReportSummaryDto> = {}): ReportSummaryDto => ({
  id: "r1", type: "missing_postbox", status: "pending", createdAtMs: 1, reporterUid: "u", reporterName: null,
  lat: 51, lng: -1, postboxId: null, currentMonarch: null, hasSuggestedMonarch: false, suggestedMonarch: null,
  suggestedReference: null, photoCount: 0, hasNote: false, reviewedAtMs: null, reviewedBy: null, reviewedByName: null,
  reviewNote: null, finalMonarch: null, finalReference: null, osmStatus: null, rescoredClaims: null, affectedUsers: null,
  rescoreTotalDelta: null, osmUploadedAtMs: null, osmSkippedAtMs: null, ...over,
});

test("defaults follow the reporter's suggestion; none means unsure", () => {
  assert.deepEqual(defaultCypher(report({ hasSuggestedMonarch: true, suggestedMonarch: "VR" })), { kind: "key", key: "VR" });
  assert.deepEqual(defaultCypher(report({ hasSuggestedMonarch: true, suggestedMonarch: null })), { kind: "plain" });
  assert.deepEqual(defaultCypher(report({ type: "wrong_cypher", currentMonarch: "EIIR" })), { kind: "unsure" });
  assert.equal(initialDecision(report({ suggestedReference: "AB1 2" })).reference, "AB1 2");
});

test("unsure is only offered when omitting the cypher can't fall back to a suggestion", () => {
  assert.equal(unsureAllowed(report()), true);
  assert.equal(unsureAllowed(report({ hasSuggestedMonarch: true, suggestedMonarch: "VR" })), false);
  assert.equal(unsureAllowed(report({ type: "wrong_cypher" })), false);
});

test("accept payload: explicit cypher, explicit reference, optional note", () => {
  const d: DecisionState = { mode: "accept", cypher: { kind: "plain" }, reference: "  ", note: " Looks right " };
  assert.deepEqual(buildReviewRequest(d), { decision: "accept", finalMonarch: null, finalReference: "", reviewNote: "Looks right" });
  assert.deepEqual(buildReviewRequest({ ...d, cypher: { kind: "unsure" }, note: "" }), { decision: "accept", finalReference: "" });
  assert.deepEqual(buildReviewRequest({ ...d, cypher: { kind: "key", key: "GR" }, reference: "N1 1" }).finalMonarch, "GR");
});

test("reject payload carries only the note", () => {
  assert.deepEqual(buildReviewRequest({ mode: "reject", cypher: { kind: "key", key: "VR" }, reference: "x", note: "" }), { decision: "reject" });
});

test("impact param", () => {
  assert.equal(impactParam({ kind: "key", key: "VR" }), "VR");
  assert.equal(impactParam({ kind: "plain" }), "plain");
  assert.equal(impactParam({ kind: "unsure" }), null);
});

const ctx = (over: Partial<ConfirmContext> = {}): ConfirmContext => ({
  report: report(),
  decision: { mode: "accept", cypher: { kind: "unsure" }, reference: "", note: "" },
  impactReady: false,
  flags: [],
  override: false,
  noteMax: 280,
  referenceMax: 40,
  writesBlocked: false,
  ...over,
});

test("confirm guards", () => {
  assert.equal(confirmBlocker(ctx()), null, "a missing box with no suggestion may be accepted as unsure");
  assert.match(confirmBlocker(ctx({ decision: { mode: "idle", cypher: { kind: "plain" }, reference: "", note: "" } })) ?? "", /accept/);
  assert.match(confirmBlocker(ctx({ writesBlocked: true })) ?? "", /Maintenance/);
  const cypherReport = report({ type: "wrong_cypher", postboxId: "osm_1" });
  assert.match(confirmBlocker(ctx({ report: cypherReport })) ?? "", /Pick the cypher/);
  const picked = { mode: "accept" as const, cypher: { kind: "key" as const, key: "GR" }, reference: "", note: "" };
  assert.match(confirmBlocker(ctx({ report: cypherReport, decision: picked })) ?? "", /impact preview/);
  assert.equal(confirmBlocker(ctx({ report: cypherReport, decision: picked, impactReady: true })), null);
  const high = [{ severity: "high" as const, message: "dup" }];
  assert.match(confirmBlocker(ctx({ flags: high })) ?? "", /Shift\+Enter/);
  assert.equal(confirmBlocker(ctx({ flags: high, override: true })), null);
  assert.equal(confirmBlocker(ctx({ flags: high, decision: { mode: "reject", cypher: { kind: "unsure" }, reference: "", note: "" } })), null, "duplicates never block a reject");
  assert.match(confirmBlocker(ctx({ decision: { mode: "reject", cypher: { kind: "unsure" }, reference: "", note: "x".repeat(281) } })) ?? "", /280/);
});
