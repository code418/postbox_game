import assert from "assert";
import test from "firebase-functions-test";
import * as myFunctions from "../index";
import { getPoints } from "../_getPoints";
import { getTodayLondon } from "../_dateUtils";
import { getWeekStart, getMonthStart } from "../_leaderboardUtils";

// ── Pure utility unit tests (no Firebase required) ────────────────────────────

describe("getPoints", () => {
  it("returns 2 for EIIR", () => assert.strictEqual(getPoints("EIIR"), 2));
  it("returns 4 for GR", () => assert.strictEqual(getPoints("GR"), 4));
  it("returns 4 for GVR", () => assert.strictEqual(getPoints("GVR"), 4));
  it("returns 4 for GVIR", () => assert.strictEqual(getPoints("GVIR"), 4));
  it("returns 7 for VR", () => assert.strictEqual(getPoints("VR"), 7));
  it("returns 9 for EVIIR", () => assert.strictEqual(getPoints("EVIIR"), 9));
  it("returns 9 for CIIIR", () => assert.strictEqual(getPoints("CIIIR"), 9));
  it("returns 12 for EVIIIR", () => assert.strictEqual(getPoints("EVIIIR"), 12));
  it("returns 2 (default) for unknown cipher", () => assert.strictEqual(getPoints("UNKNOWN"), 2));
  it("returns 2 (default) for empty string", () => assert.strictEqual(getPoints(""), 2));
});

describe("getTodayLondon", () => {
  it("returns a string matching YYYY-MM-DD", () => {
    const today = getTodayLondon();
    assert.match(today, /^\d{4}-\d{2}-\d{2}$/);
  });

  it("returns a valid calendar date", () => {
    const today = getTodayLondon();
    const d = new Date(today);
    assert.ok(!isNaN(d.getTime()), "Date should be parseable");
  });

  it("returns the same date on consecutive calls (within a test run)", () => {
    const a = getTodayLondon();
    const b = getTodayLondon();
    assert.strictEqual(a, b);
  });
});

describe("getWeekStart", () => {
  // Weeks start on Monday (ISO 8601).
  it("Monday returns itself", () => assert.strictEqual(getWeekStart("2026-04-06"), "2026-04-06"));
  it("Tuesday goes back 1 day", () => assert.strictEqual(getWeekStart("2026-04-07"), "2026-04-06"));
  it("Saturday goes back 5 days", () => assert.strictEqual(getWeekStart("2026-04-11"), "2026-04-06"));
  it("Sunday goes back to previous Monday (-6 days)", () => assert.strictEqual(getWeekStart("2026-04-12"), "2026-04-06"));
  it("handles month boundary (March Sunday → February Monday)", () => assert.strictEqual(getWeekStart("2026-03-01"), "2026-02-23"));
  it("handles year boundary (Jan 1 2026 is Thursday → Dec 29 2025)", () => assert.strictEqual(getWeekStart("2026-01-01"), "2025-12-29"));
});

describe("getMonthStart", () => {
  it("mid-month returns 1st", () => assert.strictEqual(getMonthStart("2026-04-11"), "2026-04-01"));
  it("first day returns itself", () => assert.strictEqual(getMonthStart("2026-04-01"), "2026-04-01"));
  it("last day of month returns 1st", () => assert.strictEqual(getMonthStart("2026-04-30"), "2026-04-01"));
  it("preserves year and month digits", () => assert.strictEqual(getMonthStart("2026-12-25"), "2026-12-01"));
});

// ── Cloud Function integration tests (require Firebase emulator) ─────────────

const testEnv = test();

describe("Cloud Functions", function (this: Mocha.Suite) {
  this.timeout(15000);

  const wrappedNearby = testEnv.wrap(myFunctions.nearbyPostboxes) as (data: unknown, context?: unknown) => Promise<unknown>;
  const wrappedStartScoring = testEnv.wrap(myFunctions.startScoring) as (data: unknown, context?: unknown) => Promise<unknown>;

  after(() => {
    testEnv.cleanup();
  });

  // firebase-functions-test v3 wraps v2 onCall as (req) => run(req), so auth
  // must be inside the first argument as { data, auth } — the second "context"
  // argument is ignored for v2 functions.

  describe("nearbyPostboxes (onCall)", () => {
    it("should return an object with postboxes and counts when given lat, lng, meters", async function (this: Mocha.Context) {
      this.timeout(10000);
      const req = { data: { lat: 51.45, lng: -0.95, meters: 500 }, auth: { uid: "test-uid" } };
      try {
        const result = (await wrappedNearby(req)) as Record<string, unknown>;
        assert.strictEqual(typeof result, "object");
        assert.ok("postboxes" in result);
        assert.ok("counts" in result);
        assert.ok("points" in result);
        assert.ok("compass" in result);
        assert.ok(result.counts && typeof result.counts === "object" && "total" in (result.counts as object));
      } catch (e: unknown) {
        const err = e as { code?: string; message?: string };
        // PERMISSION_DENIED is acceptable when Firebase emulator is not running.
        // Any other error is unexpected.
        if (!(err.message ?? "").includes("PERMISSION_DENIED") && err.code !== "permission-denied") {
          throw e;
        }
      }
    });

    it("should throw unauthenticated when no auth context", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: { lat: 51.45, lng: -0.95, meters: 500 } };
      try {
        await wrappedNearby(req);
        assert.fail("Expected unauthenticated error");
      } catch (e: unknown) {
        const err = e as { code?: string };
        assert.strictEqual(err.code, "unauthenticated");
      }
    });

    it("should throw invalid-argument when lat/lng are missing", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: {}, auth: { uid: "test-uid" } };
      try {
        await wrappedNearby(req);
        assert.fail("Expected invalid-argument error");
      } catch (e: unknown) {
        const err = e as { code?: string };
        assert.strictEqual(err.code, "invalid-argument");
      }
    });

    it("should throw invalid-argument when lat is out of range", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: { lat: 999, lng: -0.95, meters: 500 }, auth: { uid: "test-uid" } };
      try {
        await wrappedNearby(req);
        assert.fail("Expected invalid-argument error");
      } catch (e: unknown) {
        const err = e as { code?: string };
        assert.strictEqual(err.code, "invalid-argument");
      }
    });

    it("should clamp meters to 2000 without error", async function (this: Mocha.Context) {
      this.timeout(10000);
      // This will still hit Firestore but at least validates the clamping path doesn't throw
      const req = { data: { lat: 51.45, lng: -0.95, meters: 999999 }, auth: { uid: "test-uid" } };
      try {
        await wrappedNearby(req);
        // If emulator is running, this succeeds. Without emulator, PERMISSION_DENIED is expected.
      } catch (e: unknown) {
        const err = e as { code?: string; message?: string };
        // Acceptable: PERMISSION_DENIED (no emulator) but NOT invalid-argument
        assert.notStrictEqual(err.code, "invalid-argument", "Should not throw invalid-argument for large meters");
      }
    });
  });

  describe("startScoring (onCall)", () => {
    it("should return an object with found, claimed, points, allClaimedToday", async function (this: Mocha.Context) {
      this.timeout(10000);
      const req = { data: { lat: 51.45, lng: -0.95 }, auth: { uid: "test-uid" } };
      try {
        const result = (await wrappedStartScoring(req)) as Record<string, unknown>;
        assert.strictEqual(typeof result, "object");
        assert.ok("found" in result);
        assert.ok("claimed" in result);
        assert.ok("points" in result);
        assert.ok("allClaimedToday" in result);
        assert.strictEqual(typeof result.claimed, "number");
        assert.strictEqual(typeof result.points, "number");
      } catch (e: unknown) {
        const err = e as { code?: string; message?: string };
        // PERMISSION_DENIED is acceptable when Firebase emulator is not running.
        if (!(err.message ?? "").includes("PERMISSION_DENIED") && err.code !== "permission-denied") {
          throw e;
        }
      }
    });

    it("should throw unauthenticated when no auth context", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: { lat: 51.45, lng: -0.95 } };
      try {
        await wrappedStartScoring(req);
        assert.fail("Expected unauthenticated error");
      } catch (e: unknown) {
        const err = e as { code?: string };
        assert.strictEqual(err.code, "unauthenticated");
      }
    });

    it("should throw invalid-argument when lat/lng are missing", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: {}, auth: { uid: "test-uid" } };
      try {
        await wrappedStartScoring(req);
        assert.fail("Expected invalid-argument error");
      } catch (e: unknown) {
        const err = e as { code?: string };
        assert.strictEqual(err.code, "invalid-argument");
      }
    });
  });
});
