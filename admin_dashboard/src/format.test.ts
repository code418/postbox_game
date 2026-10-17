import { test } from "node:test";
import assert from "node:assert/strict";
import { monthYear, yearsBefore } from "./format.ts";

test("Street View capture months read as words", () => {
  assert.equal(monthYear("2023-06"), "June 2023");
  assert.equal(monthYear("2019-12"), "December 2019");
  assert.equal(monthYear("2019-13"), null);
  assert.equal(monthYear("June"), null);
  assert.equal(monthYear(null), null);
});

test("imagery age counts whole years before the report", () => {
  const oct2026 = Date.UTC(2026, 9, 17);
  assert.equal(yearsBefore("2023-06", oct2026), 3);
  assert.equal(yearsBefore("2023-11", oct2026), 2);
  assert.equal(yearsBefore("2026-10", oct2026), 0);
  assert.equal(yearsBefore("2027-01", oct2026), 0, "never negative");
  assert.equal(yearsBefore(null, oct2026), null);
  assert.equal(yearsBefore("2023-06", null), null);
});
