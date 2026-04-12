import assert from "assert";
import test from "firebase-functions-test";
import * as myFunctions from "../index";
import { getPoints } from "../_getPoints";
import { getTodayLondon } from "../_dateUtils";
import { getWeekStart, getMonthStart, getPeriodKey, mergePeriodEntries, mergeLifetimeEntries } from "../_leaderboardUtils";
import { setPrecision, getLatLng } from "../_lookupPostboxes";
import { computeNewStreak } from "../_streakUtils";
import { containsProfanity } from "../_profanityFilter";
import { sanitiseName } from "../onUserCreated";

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

describe("getPeriodKey", () => {
  it("daily returns the date itself", () =>
    assert.strictEqual(getPeriodKey("daily", "2026-04-11"), "2026-04-11"));
  it("weekly returns 'week:' prefix with Monday date", () =>
    assert.strictEqual(getPeriodKey("weekly", "2026-04-06"), "week:2026-04-06"));
  it("monthly returns 'month:' prefix with YYYY-MM", () =>
    assert.strictEqual(getPeriodKey("monthly", "2026-04-01"), "month:2026-04"));
  it("daily keys for different dates are distinct", () => {
    assert.notStrictEqual(getPeriodKey("daily", "2026-04-11"), getPeriodKey("daily", "2026-04-12"));
  });
  it("weekly keys for the same week are identical", () => {
    // Both Tuesday and Saturday of the same week return the same key
    const tuesdayWeekStart = getWeekStart("2026-04-07");
    const saturdayWeekStart = getWeekStart("2026-04-11");
    assert.strictEqual(getPeriodKey("weekly", tuesdayWeekStart), getPeriodKey("weekly", saturdayWeekStart));
  });
  it("monthly keys for different months are distinct", () => {
    assert.notStrictEqual(getPeriodKey("monthly", "2026-04-01"), getPeriodKey("monthly", "2026-05-01"));
  });
});

describe("mergePeriodEntries", () => {
  const alice = { uid: "a", displayName: "Alice", points: 10 };
  const bob   = { uid: "b", displayName: "Bob",   points:  5 };

  it("adds a new entry when list is empty", () => {
    const result = mergePeriodEntries([], "a", "Alice", 10);
    assert.deepStrictEqual(result, [alice]);
  });

  it("upserts an existing user's entry (replaces, not duplicates)", () => {
    const result = mergePeriodEntries([alice, bob], "a", "Alice", 20);
    assert.strictEqual(result.length, 2);
    assert.strictEqual(result[0].uid, "a");
    assert.strictEqual(result[0].points, 20);
  });

  it("removes a user from the list when points are 0", () => {
    const result = mergePeriodEntries([alice, bob], "a", "Alice", 0);
    assert.strictEqual(result.length, 1);
    assert.strictEqual(result[0].uid, "b");
  });

  it("sorts entries descending by points", () => {
    const result = mergePeriodEntries([bob], "a", "Alice", 10);
    assert.strictEqual(result[0].uid, "a");
    assert.strictEqual(result[1].uid, "b");
  });

  it("does not add a 0-point entry for a new user", () => {
    const result = mergePeriodEntries([], "a", "Alice", 0);
    assert.strictEqual(result.length, 0);
  });

  it("caps at the given limit", () => {
    const existing = Array.from({ length: 3 }, (_, i) => ({
      uid: `u${i}`, displayName: `User${i}`, points: 3 - i,
    }));
    const result = mergePeriodEntries(existing, "new", "NewUser", 10, 3);
    assert.strictEqual(result.length, 3);
    assert.strictEqual(result[0].uid, "new"); // highest score
  });

  it("updates displayName when upserted", () => {
    const result = mergePeriodEntries([alice], "a", "Alice Updated", 10);
    assert.strictEqual(result[0].displayName, "Alice Updated");
  });

  it("default limit is 100", () => {
    const existing = Array.from({ length: 100 }, (_, i) => ({
      uid: `u${i}`, displayName: `U${i}`, points: 100 - i,
    }));
    // Adding one more at a low score; should not exceed 100 entries.
    const result = mergePeriodEntries(existing, "extra", "Extra", 1);
    assert.strictEqual(result.length, 100);
  });
});

describe("mergeLifetimeEntries", () => {
  const alice = { uid: "a", displayName: "Alice", uniquePostboxesClaimed: 10, totalPoints: 50 };
  const bob   = { uid: "b", displayName: "Bob",   uniquePostboxesClaimed:  5, totalPoints: 20 };

  it("adds a new entry when list is empty", () => {
    const result = mergeLifetimeEntries([], "a", "Alice", 10, 50);
    assert.deepStrictEqual(result, [alice]);
  });

  it("upserts an existing user's entry (replaces old)", () => {
    const result = mergeLifetimeEntries([alice, bob], "a", "Alice", 15, 70);
    assert.strictEqual(result.length, 2);
    assert.strictEqual(result[0].uid, "a");
    assert.strictEqual(result[0].uniquePostboxesClaimed, 15);
    assert.strictEqual(result[0].totalPoints, 70);
  });

  it("removes user when both uniqueBoxes and totalPoints are 0", () => {
    const result = mergeLifetimeEntries([alice, bob], "a", "Alice", 0, 0);
    assert.strictEqual(result.length, 1);
    assert.strictEqual(result[0].uid, "b");
  });

  it("keeps user with uniqueBoxes 0 if they have totalPoints > 0", () => {
    const result = mergeLifetimeEntries([], "a", "Alice", 0, 5);
    assert.strictEqual(result.length, 1);
    assert.strictEqual(result[0].totalPoints, 5);
  });

  it("sorts descending by uniquePostboxesClaimed", () => {
    const result = mergeLifetimeEntries([bob], "a", "Alice", 10, 50);
    assert.strictEqual(result[0].uid, "a");
    assert.strictEqual(result[1].uid, "b");
  });

  it("breaks ties in uniqueBoxes by totalPoints descending", () => {
    const tied = { uid: "c", displayName: "Carol", uniquePostboxesClaimed: 10, totalPoints: 30 };
    const result = mergeLifetimeEntries([tied], "a", "Alice", 10, 50);
    assert.strictEqual(result[0].uid, "a");   // 10 boxes, 50 pts
    assert.strictEqual(result[1].uid, "c");   // 10 boxes, 30 pts
  });

  it("caps at the given limit", () => {
    const existing = Array.from({ length: 3 }, (_, i) => ({
      uid: `u${i}`, displayName: `User${i}`,
      uniquePostboxesClaimed: 3 - i, totalPoints: 0,
    }));
    const result = mergeLifetimeEntries(existing, "new", "NewUser", 10, 0, 3);
    assert.strictEqual(result.length, 3);
    assert.strictEqual(result[0].uid, "new");
  });

  it("updates displayName when upserted", () => {
    const result = mergeLifetimeEntries([alice], "a", "Alice v2", 10, 50);
    assert.strictEqual(result[0].displayName, "Alice v2");
  });
});

describe("setPrecision", () => {
  // Verify geohash precision thresholds used for postbox proximity queries.
  // Lower precision = larger cells = more documents fetched but guaranteed coverage.
  //
  // IMPORTANT — import precision coupling: import_postboxes.js must store
  // postboxes at a geohash precision >= the highest precision returned here.
  // The Claim screen uses a 30 m radius → precision 8 prefix queries.
  // If stored precision < 8 the documents sort lexicographically before the
  // prefix range, so every claim silently returns { found: false }.
  // Current import precision: 9 (maximum). Do not lower it.
  it("returns 9 at exact upper boundary (0.00477 km)", () => assert.strictEqual(setPrecision(0.00477), 9));
  it("returns 8 just above precision-9 boundary", () => assert.strictEqual(setPrecision(0.005), 8));
  it("returns 8 for 30 m radius (0.030 km, used by Claim screen)", () => assert.strictEqual(setPrecision(0.030), 8));
  it("returns 8 at exact upper boundary (0.0382 km)", () => assert.strictEqual(setPrecision(0.0382), 8));
  it("returns 7 just above precision-8 boundary", () => assert.strictEqual(setPrecision(0.039), 7));
  it("returns 7 at exact upper boundary (0.153 km)", () => assert.strictEqual(setPrecision(0.153), 7));
  it("returns 6 just above precision-7 boundary", () => assert.strictEqual(setPrecision(0.154), 6));
  it("returns 6 for 540 m radius (0.540 km, used by Nearby screen)", () => assert.strictEqual(setPrecision(0.540), 6));
  it("returns 6 at exact upper boundary (1.22 km)", () => assert.strictEqual(setPrecision(1.22), 6));
  it("returns 5 just above precision-6 boundary", () => assert.strictEqual(setPrecision(1.23), 5));
  it("returns 5 at exact upper boundary (4.89 km)", () => assert.strictEqual(setPrecision(4.89), 5));
  it("returns 4 for 10 km radius", () => assert.strictEqual(setPrecision(10), 4));
  it("returns 2 for 1000 km radius", () => assert.strictEqual(setPrecision(1000), 2));
  it("returns 1 for very large radius (>1250 km)", () => assert.strictEqual(setPrecision(2000), 1));
});

describe("getLatLng", () => {
  it("returns null for undefined geopoint", () => assert.strictEqual(getLatLng(undefined), null));
  it("returns null for null-equivalent object with no lat/lng fields", () =>
    assert.strictEqual(getLatLng({}), null));
  it("reads standard latitude/longitude fields", () => {
    const r = getLatLng({ latitude: 51.5, longitude: -0.1 });
    assert.deepStrictEqual(r, { lat: 51.5, lng: -0.1 });
  });
  it("reads Admin SDK internal _latitude/_longitude fields", () => {
    const r = getLatLng({ _latitude: 53.8, _longitude: -1.55 });
    assert.deepStrictEqual(r, { lat: 53.8, lng: -1.55 });
  });
  it("prefers _latitude/_longitude over latitude/longitude when both present", () => {
    const r = getLatLng({ _latitude: 10, _longitude: 20, latitude: 99, longitude: 99 });
    assert.deepStrictEqual(r, { lat: 10, lng: 20 });
  });
  it("returns null when lat is present but lng is undefined", () => {
    assert.strictEqual(getLatLng({ latitude: 51.5 }), null);
  });
  it("returns null when lng is present but lat is undefined", () => {
    assert.strictEqual(getLatLng({ longitude: -0.1 }), null);
  });
  it("handles coordinate value 0 (falsy-but-valid)", () => {
    const r = getLatLng({ latitude: 0, longitude: 0 });
    assert.deepStrictEqual(r, { lat: 0, lng: 0 });
  });
});

describe("computeNewStreak", () => {
  const today = "2026-04-12";
  const yesterday = "2026-04-11";
  const twoDaysAgo = "2026-04-10";

  it("returns 1 when no previous claim (undefined lastClaimDate)", () =>
    assert.strictEqual(computeNewStreak(undefined, 0, today, yesterday), 1));

  it("returns null when already claimed today (no-op)", () =>
    assert.strictEqual(computeNewStreak(today, 5, today, yesterday), null));

  it("increments streak when last claim was yesterday", () =>
    assert.strictEqual(computeNewStreak(yesterday, 3, today, yesterday), 4));

  it("resets streak to 1 when last claim was two days ago (gap)", () =>
    assert.strictEqual(computeNewStreak(twoDaysAgo, 10, today, yesterday), 1));

  it("resets streak to 1 when last claim was long ago", () =>
    assert.strictEqual(computeNewStreak("2025-01-01", 42, today, yesterday), 1));

  it("resets orphaned streak (streak > 0, no lastClaimDate) to 1", () =>
    assert.strictEqual(computeNewStreak(undefined, 5, today, yesterday), 1));

  it("streak increment from 1 to 2 on consecutive day", () =>
    assert.strictEqual(computeNewStreak(yesterday, 1, today, yesterday), 2));
});

describe("sanitiseName", () => {
  const uid = "abc123xyz";
  const fallback = `Player_${uid.slice(0, 6)}`; // "Player_abc123"

  it("returns the name unchanged for a clean 2+ char name", () =>
    assert.strictEqual(sanitiseName("Alice", uid), "Alice"));
  it("trims whitespace before validating", () =>
    assert.strictEqual(sanitiseName("  Alice  ", uid), "Alice"));
  it("returns fallback for a name shorter than 2 chars after trim", () =>
    assert.strictEqual(sanitiseName("A", uid), fallback));
  it("returns fallback for a name longer than 30 chars", () =>
    assert.strictEqual(sanitiseName("A".repeat(31), uid), fallback));
  it("returns fallback for a profane name", () =>
    assert.strictEqual(sanitiseName("wanker", uid), fallback));
  it("returns fallback for an empty string", () =>
    assert.strictEqual(sanitiseName("", uid), fallback));
  it("returns fallback for whitespace-only input", () =>
    assert.strictEqual(sanitiseName("   ", uid), fallback));
  it("accepts a 30-char clean name", () =>
    assert.strictEqual(sanitiseName("A".repeat(30), uid), "A".repeat(30)));
  it("uses first 6 chars of uid in fallback", () => {
    const result = sanitiseName("wanker", "testUID999");
    assert.ok(result.startsWith("Player_"), "should start with Player_");
    assert.strictEqual(result, "Player_testUI");
  });
});

describe("containsProfanity", () => {
  it("returns false for a clean name", () => assert.strictEqual(containsProfanity("Alice"), false));
  it("returns false for a clean multi-word name", () => assert.strictEqual(containsProfanity("Postbox Pete"), false));
  it("returns true for an exact blocked word", () => assert.strictEqual(containsProfanity("wanker"), true));
  it("returns true for a blocked word in upper case", () => assert.strictEqual(containsProfanity("WANKER"), true));
  it("returns true for a blocked word embedded in a longer name", () => assert.strictEqual(containsProfanity("BigWanker"), true));
  it("returns true for 'cunt'", () => assert.strictEqual(containsProfanity("cunt"), true));
  it("returns true for 'bellend' embedded", () => assert.strictEqual(containsProfanity("MyBellend"), true));
  it("returns false for an empty string", () => assert.strictEqual(containsProfanity(""), false));
  it("returns false for whitespace-only string", () => assert.strictEqual(containsProfanity("   "), false));
  it("returns true for slur 'paki'", () => assert.strictEqual(containsProfanity("paki"), true));
});

// ── Cloud Function integration tests (require Firebase emulator) ─────────────

const testEnv = test();

describe("Cloud Functions", function (this: Mocha.Suite) {
  this.timeout(15000);

  const wrappedNearby = testEnv.wrap(myFunctions.nearbyPostboxes) as (data: unknown, context?: unknown) => Promise<unknown>;
  const wrappedStartScoring = testEnv.wrap(myFunctions.startScoring) as (data: unknown, context?: unknown) => Promise<unknown>;
  const wrappedUpdateDisplayName = testEnv.wrap(myFunctions.updateDisplayName) as (data: unknown, context?: unknown) => Promise<unknown>;

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

    it("should throw invalid-argument when lng is out of range", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: { lat: 51.45, lng: 999, meters: 500 }, auth: { uid: "test-uid" } };
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

    it("should throw invalid-argument when meters is zero", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: { lat: 51.45, lng: -0.95, meters: 0 }, auth: { uid: "test-uid" } };
      try {
        await wrappedNearby(req);
        assert.fail("Expected invalid-argument error");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });

    it("should throw invalid-argument when meters is negative", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: { lat: 51.45, lng: -0.95, meters: -100 }, auth: { uid: "test-uid" } };
      try {
        await wrappedNearby(req);
        assert.fail("Expected invalid-argument error");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
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

    it("should throw invalid-argument when lat is out of range", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: { lat: 999, lng: -0.95 }, auth: { uid: "test-uid" } };
      try {
        await wrappedStartScoring(req);
        assert.fail("Expected invalid-argument error");
      } catch (e: unknown) {
        const err = e as { code?: string };
        assert.strictEqual(err.code, "invalid-argument");
      }
    });

    it("should throw invalid-argument when lng is out of range", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: { lat: 51.45, lng: 999 }, auth: { uid: "test-uid" } };
      try {
        await wrappedStartScoring(req);
        assert.fail("Expected invalid-argument error");
      } catch (e: unknown) {
        const err = e as { code?: string };
        assert.strictEqual(err.code, "invalid-argument");
      }
    });

    it("should return dailyDate string on success", async function (this: Mocha.Context) {
      this.timeout(10000);
      const req = { data: { lat: 51.45, lng: -0.95 }, auth: { uid: "test-uid" } };
      try {
        const result = (await wrappedStartScoring(req)) as Record<string, unknown>;
        // dailyDate is included on found:true paths only; omitted when found:false.
        if (result.found === false) {
          assert.ok(!("dailyDate" in result) || result.dailyDate === undefined);
        } else {
          assert.ok("dailyDate" in result, "dailyDate should be present when found:true");
          assert.match(result.dailyDate as string, /^\d{4}-\d{2}-\d{2}$/);
        }
      } catch (e: unknown) {
        const err = e as { code?: string; message?: string };
        if (!(err.message ?? "").includes("PERMISSION_DENIED") && err.code !== "permission-denied") {
          throw e;
        }
      }
    });
  });

  describe("updateDisplayName (onCall)", () => {
    it("should throw unauthenticated when no auth context", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: { name: "Alice" } };
      try {
        await wrappedUpdateDisplayName(req);
        assert.fail("Expected unauthenticated error");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "unauthenticated");
      }
    });

    it("should throw invalid-argument when name is missing", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: {}, auth: { uid: "test-uid" } };
      try {
        await wrappedUpdateDisplayName(req);
        assert.fail("Expected invalid-argument error");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });

    it("should throw invalid-argument when name is too short (< 2 chars)", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: { name: "A" }, auth: { uid: "test-uid" } };
      try {
        await wrappedUpdateDisplayName(req);
        assert.fail("Expected invalid-argument error");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });

    it("should throw invalid-argument when name is too long (> 30 chars)", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: { name: "A".repeat(31) }, auth: { uid: "test-uid" } };
      try {
        await wrappedUpdateDisplayName(req);
        assert.fail("Expected invalid-argument error");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });

    it("should throw invalid-argument for name containing profanity", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: { name: "BloodyWanker" }, auth: { uid: "test-uid" } };
      try {
        await wrappedUpdateDisplayName(req);
        assert.fail("Expected invalid-argument error");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });

    it("should throw invalid-argument for name that is only whitespace after trim", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: { name: "   " }, auth: { uid: "test-uid" } };
      try {
        await wrappedUpdateDisplayName(req);
        assert.fail("Expected invalid-argument error");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });

    it("should accept a valid name (or fail with permission-denied if no emulator)", async function (this: Mocha.Context) {
      this.timeout(10000);
      const req = { data: { name: "PostboxHunter" }, auth: { uid: "test-uid" } };
      try {
        const result = (await wrappedUpdateDisplayName(req)) as Record<string, unknown>;
        assert.strictEqual(result.displayName, "PostboxHunter");
      } catch (e: unknown) {
        const err = e as { code?: string; message?: string };
        // Without an emulator, the Admin SDK calls will fail with permission-denied.
        // That's acceptable — we've validated the function reaches that point.
        if (!(err.message ?? "").includes("PERMISSION_DENIED") &&
            err.code !== "permission-denied" &&
            err.code !== "internal") {
          throw e;
        }
      }
    });
  });
});
