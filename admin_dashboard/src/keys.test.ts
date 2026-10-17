import { test } from "node:test";
import assert from "node:assert/strict";
import { keyToCommand, type KeyInput } from "./keys.ts";

const k = (key: string, extra: Partial<KeyInput> = {}): KeyInput => ({
  key, shiftKey: false, ctrlKey: false, metaKey: false, altKey: false, inTextField: false, ...extra,
});

test("navigation keys", () => {
  assert.deepEqual(keyToCommand(k("j"), "idle", false), { type: "next" });
  assert.deepEqual(keyToCommand(k("ArrowDown"), "accept", false), { type: "next" });
  assert.deepEqual(keyToCommand(k("k"), "idle", false), { type: "prev" });
  assert.deepEqual(keyToCommand(k("ArrowUp"), "idle", false), { type: "prev" });
});

test("digits pick cyphers when idle or accepting, presets when rejecting", () => {
  assert.deepEqual(keyToCommand(k("3"), "idle", false), { type: "cypher", digit: 3 });
  assert.deepEqual(keyToCommand(k("0"), "accept", false), { type: "cypher", digit: 0 });
  assert.deepEqual(keyToCommand(k("2"), "reject", false), { type: "preset", index: 1 });
  assert.equal(keyToCommand(k("0"), "reject", false), null);
});

test("Enter confirms only when a decision is staged; Shift overrides", () => {
  assert.equal(keyToCommand(k("Enter"), "idle", false), null);
  assert.deepEqual(keyToCommand(k("Enter"), "accept", false), { type: "confirm", override: false });
  assert.deepEqual(keyToCommand(k("Enter", { shiftKey: true }), "reject", false), { type: "confirm", override: true });
});

test("inside a text field only Esc and Enter do anything", () => {
  const t = { inTextField: true };
  assert.equal(keyToCommand(k("j", t), "accept", false), null);
  assert.equal(keyToCommand(k("3", t), "accept", false), null);
  assert.deepEqual(keyToCommand(k("Escape", t), "accept", false), { type: "cancel" });
  assert.deepEqual(keyToCommand(k("Enter", t), "accept", false), { type: "confirm", override: false });
  assert.equal(keyToCommand(k("Enter", t), "idle", false), null);
});

test("g prefix switches views and swallows anything else", () => {
  assert.deepEqual(keyToCommand(k("g"), "idle", false), { type: "goPrefix" });
  assert.deepEqual(keyToCommand(k("h"), "idle", true), { type: "view", view: "history" });
  assert.deepEqual(keyToCommand(k("o"), "idle", true), { type: "view", view: "osm" });
  assert.deepEqual(keyToCommand(k("q"), "idle", true), { type: "view", view: "queue" });
  assert.equal(keyToCommand(k("a"), "idle", true), null);
});

test("modifier chords are left to the browser", () => {
  assert.equal(keyToCommand(k("r", { ctrlKey: true }), "idle", false), null);
  assert.equal(keyToCommand(k("a", { metaKey: true }), "idle", false), null);
  assert.equal(keyToCommand(k("j", { altKey: true }), "idle", false), null);
});

test("letters", () => {
  assert.deepEqual(keyToCommand(k("a"), "idle", false), { type: "stageAccept" });
  assert.deepEqual(keyToCommand(k("r"), "accept", false), { type: "stageReject" });
  assert.deepEqual(keyToCommand(k("R", { shiftKey: true }), "idle", false), { type: "batchReject" });
  assert.deepEqual(keyToCommand(k("x"), "idle", false), { type: "toggleBatch" });
  assert.deepEqual(keyToCommand(k("?", { shiftKey: true }), "idle", false), { type: "help" });
  assert.equal(keyToCommand(k("z"), "idle", false), null);
});
