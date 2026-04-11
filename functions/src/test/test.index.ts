import assert from "assert";
import test from "firebase-functions-test";
import * as myFunctions from "../index";

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
      const result = (await wrappedNearby(req)) as Record<string, unknown>;
      assert.strictEqual(typeof result, "object");
      assert.ok("postboxes" in result);
      assert.ok("counts" in result);
      assert.ok("points" in result);
      assert.ok("compass" in result);
      assert.ok(result.counts && typeof result.counts === "object" && "total" in (result.counts as object));
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
  });

  describe("startScoring (onCall)", () => {
    it("should return an object with found, claimed, points, allClaimedToday", async function (this: Mocha.Context) {
      this.timeout(10000);
      const req = { data: { lat: 51.45, lng: -0.95 }, auth: { uid: "test-uid" } };
      const result = (await wrappedStartScoring(req)) as Record<string, unknown>;
      assert.strictEqual(typeof result, "object");
      assert.ok("found" in result);
      assert.ok("claimed" in result);
      assert.ok("points" in result);
      assert.ok("allClaimedToday" in result);
      assert.strictEqual(typeof result.claimed, "number");
      assert.strictEqual(typeof result.points, "number");
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
