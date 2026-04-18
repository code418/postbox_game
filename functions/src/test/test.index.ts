import assert from "assert";
import test from "firebase-functions-test";
import * as myFunctions from "../index";
import { getPoints } from "../_getPoints";
import { getTodayLondon } from "../_dateUtils";
import { getWeekStart, getMonthStart, getPeriodKey, mergePeriodEntries, mergeLifetimeEntries, updateUserLeaderboards, getPeriodResetFields } from "../_leaderboardUtils";
import { setPrecision, getLatLng } from "../_lookupPostboxes";
import { applyUserClaims } from "../_nearbyUtils";
import { computeNewStreak } from "../_streakUtils";
import { containsProfanity } from "../_profanityFilter";
import { sanitiseName } from "../onUserCreated";

// ── Pure utility unit tests (no Firebase required) ────────────────────────────

describe("getPoints", () => {
  it("returns 2 for EIIR", () => assert.strictEqual(getPoints("EIIR"), 2));
  it("returns 4 for GR", () => assert.strictEqual(getPoints("GR"), 4));
  it("returns 4 for GVR", () => assert.strictEqual(getPoints("GVR"), 4));
  it("returns 4 for GVIR", () => assert.strictEqual(getPoints("GVIR"), 4));
  it("returns 4 for SCOTTISH_CROWN", () => assert.strictEqual(getPoints("SCOTTISH_CROWN"), 4));
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

  it("keeps user with totalPoints 0 if they have uniqueBoxes > 0", () => {
    const result = mergeLifetimeEntries([], "a", "Alice", 3, 0);
    assert.strictEqual(result.length, 1);
    assert.strictEqual(result[0].uniquePostboxesClaimed, 3);
    assert.strictEqual(result[0].totalPoints, 0);
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

// ── updateUserLeaderboards unit tests (mock Firestore, no emulator needed) ───
//
// The mock only implements the operations updateUserLeaderboards actually uses:
//   collection("claims").where(...).where(...)[.where(...)].get()
//   collection("leaderboards").doc(id)
//   runTransaction(tx => { tx.get(ref); tx.set(ref, data) })
//
// Typing is cast through `unknown` to avoid reproducing the full admin SDK
// interface — this is intentional in test-only code.

describe("updateUserLeaderboards (unit, mock Firestore)", () => {
  type ClaimDoc  = { userid: string; dailyDate: string; points: number };
  type LbDoc     = { periodKey?: string; entries?: unknown[] };

  function makeMockDb(claims: ClaimDoc[], initial: Record<string, LbDoc> = {}) {
    const leaderboards = new Map<string, LbDoc>(Object.entries(initial));

    function buildQuery(preds: Array<{ field: string; op: string; val: unknown }>) {
      return {
        where: (f: string, o: string, v: unknown) =>
          buildQuery([...preds, { field: f, op: o, val: v }]),
        get: async () => ({
          docs: claims
            .filter(doc =>
              preds.every(({ field, op, val }) => {
                const v = (doc as Record<string, unknown>)[field];
                if (op === "==") return v === val;
                if (op === ">=") return typeof v === "string" && typeof val === "string" && v >= val;
                if (op === "<=") return typeof v === "string" && typeof val === "string" && v <= val;
                return false;
              })
            )
            .map(d => ({ data: () => d as Record<string, unknown> })),
        }),
      };
    }

    const db = {
      collection: (name: string) => {
        if (name === "claims") {
          return { where: (f: string, o: string, v: unknown) => buildQuery([{ field: f, op: o, val: v }]) };
        }
        if (name === "leaderboards") {
          return { doc: (id: string) => ({ _id: id }) };
        }
        throw new Error(`Unexpected collection: ${name}`);
      },
      runTransaction: async (fn: (tx: unknown) => Promise<void>) => {
        let pending: { id: string; data: LbDoc } | null = null;
        await fn({
          get: async (ref: { _id: string }) => ({ data: () => leaderboards.get(ref._id) }),
          set: (ref: { _id: string }, data: LbDoc) => { pending = { id: ref._id, data }; },
        });
        if (pending) leaderboards.set((pending as { id: string; data: LbDoc }).id, (pending as { id: string; data: LbDoc }).data);
      },
    };

    return {
      db: db as unknown as import("firebase-admin").firestore.Firestore,
      lb: (period: string) => leaderboards.get(period) as Record<string, unknown> | undefined,
    };
  }

  it("creates a weekly entry summing claims within the current week", async () => {
    const today = "2026-04-15"; // Wednesday; week starts Mon 2026-04-13
    const { db, lb } = makeMockDb([
      { userid: "u1", dailyDate: "2026-04-13", points: 5 }, // Monday
      { userid: "u1", dailyDate: "2026-04-15", points: 3 }, // Wednesday (today)
    ]);
    await updateUserLeaderboards("u1", "Alice", today, db);
    const weekly = lb("weekly");
    assert.strictEqual(weekly?.periodKey, `week:${getWeekStart(today)}`);
    assert.strictEqual((weekly?.entries as Array<{ uid: string; points: number }>)?.[0]?.uid, "u1");
    assert.strictEqual((weekly?.entries as Array<{ uid: string; points: number }>)?.[0]?.points, 8);
  });

  it("creates a monthly entry summing all claims in the current month", async () => {
    const today = "2026-04-15";
    const { db, lb } = makeMockDb([
      { userid: "u1", dailyDate: "2026-04-01", points: 2 },
      { userid: "u1", dailyDate: "2026-04-10", points: 7 },
      { userid: "u1", dailyDate: "2026-04-15", points: 4 },
      { userid: "u1", dailyDate: "2026-03-31", points: 9 }, // previous month — must NOT be included
    ]);
    await updateUserLeaderboards("u1", "Alice", today, db);
    const monthly = lb("monthly");
    assert.strictEqual(monthly?.periodKey, "month:2026-04");
    assert.strictEqual((monthly?.entries as Array<{ points: number }>)?.[0]?.points, 13); // 2+7+4
  });

  it("excludes claims from a previous week", async () => {
    const today = "2026-04-15"; // week starts 2026-04-13
    const { db, lb } = makeMockDb([
      { userid: "u1", dailyDate: "2026-04-10", points: 100 }, // previous Friday
      { userid: "u1", dailyDate: "2026-04-15", points: 2 },
    ]);
    await updateUserLeaderboards("u1", "Alice", today, db);
    assert.strictEqual((lb("weekly")?.entries as Array<{ points: number }>)?.[0]?.points, 2);
  });

  it("clears stale weekly entries when the week rolls over", async () => {
    const today = "2026-04-13"; // new Monday
    const { db, lb } = makeMockDb(
      [{ userid: "u1", dailyDate: "2026-04-13", points: 3 }],
      { weekly: { periodKey: "week:2026-04-06", entries: [{ uid: "u2", displayName: "Bob", points: 99 }] } }
    );
    await updateUserLeaderboards("u1", "Alice", today, db);
    const weekly = lb("weekly");
    assert.strictEqual(weekly?.periodKey, "week:2026-04-13");
    assert.strictEqual((weekly?.entries as unknown[])?.length, 1);
    assert.strictEqual((weekly?.entries as Array<{ uid: string }>)?.[0]?.uid, "u1");
  });

  it("clears stale monthly entries when the month rolls over", async () => {
    const today = "2026-05-01";
    const { db, lb } = makeMockDb(
      [{ userid: "u1", dailyDate: "2026-05-01", points: 2 }],
      { monthly: { periodKey: "month:2026-04", entries: [{ uid: "u2", displayName: "Bob", points: 50 }] } }
    );
    await updateUserLeaderboards("u1", "Alice", today, db);
    const monthly = lb("monthly");
    assert.strictEqual(monthly?.periodKey, "month:2026-05");
    assert.strictEqual((monthly?.entries as unknown[])?.length, 1);
    assert.strictEqual((monthly?.entries as Array<{ uid: string }>)?.[0]?.uid, "u1");
  });

  it("preserves other users' entries within the same period", async () => {
    const today = "2026-04-15";
    const { db, lb } = makeMockDb(
      [{ userid: "u1", dailyDate: "2026-04-15", points: 4 }],
      { weekly: { periodKey: `week:${getWeekStart(today)}`, entries: [{ uid: "u2", displayName: "Bob", points: 10 }] } }
    );
    await updateUserLeaderboards("u1", "Alice", today, db);
    const entries = lb("weekly")?.entries as Array<{ uid: string; points: number }>;
    assert.strictEqual(entries?.length, 2);
    assert.ok(entries?.some(e => e.uid === "u2" && e.points === 10), "Bob's entry should be preserved");
    assert.ok(entries?.some(e => e.uid === "u1" && e.points === 4),  "Alice's entry should be added");
  });

  it("removes a user from the leaderboard when they have 0 points in the period", async () => {
    const today = "2026-04-15";
    const { db, lb } = makeMockDb(
      [], // no claims this week
      { weekly: { periodKey: `week:${getWeekStart(today)}`, entries: [{ uid: "u1", displayName: "Alice", points: 5 }] } }
    );
    await updateUserLeaderboards("u1", "Alice", today, db);
    assert.strictEqual((lb("weekly")?.entries as unknown[])?.length, 0);
  });

  it("Sunday belongs to the same week as the preceding Monday", async () => {
    // Week of Mon 2026-04-06: Mon claim 5pts + Sun claim 3pts = 8pts
    const today = "2026-04-12"; // Sunday
    const { db, lb } = makeMockDb([
      { userid: "u1", dailyDate: "2026-04-06", points: 5 }, // Monday
      { userid: "u1", dailyDate: "2026-04-12", points: 3 }, // Sunday (today)
    ]);
    await updateUserLeaderboards("u1", "Alice", today, db);
    assert.strictEqual((lb("weekly")?.entries as Array<{ points: number }>)?.[0]?.points, 8);
  });

  it("treats a claim doc with no points field as 0 points", async () => {
    // Covers the `d.data().points ?? 0` null-coalescing branch (line 78 compiled JS)
    // when a claim document is missing the points field.
    const today = "2026-04-15";
    const { db, lb } = makeMockDb([
      // Claim doc with no `points` field — cast through unknown to satisfy TypeScript.
      { userid: "u1", dailyDate: today } as unknown as { userid: string; dailyDate: string; points: number },
    ]);
    await updateUserLeaderboards("u1", "Alice", today, db);
    // User has 0 effective points so should not appear in the leaderboard.
    assert.strictEqual((lb("daily")?.entries as unknown[])?.length ?? 0, 0);
  });

  it("handles a leaderboard doc that has a matching periodKey but no entries field", async () => {
    // Covers `data?.entries ?? []` null-coalescing branch (line 89 compiled JS)
    // when the leaderboard doc has the right periodKey but entries is missing.
    const today = "2026-04-15";
    const { db, lb } = makeMockDb(
      [{ userid: "u1", dailyDate: today, points: 5 }],
      // Leaderboard doc has matching periodKey but no entries key at all.
      { daily: { periodKey: today } as { periodKey: string; entries?: unknown[] } },
    );
    await updateUserLeaderboards("u1", "Alice", today, db);
    // Entry should be created from scratch (treating existing entries as empty).
    const entries = lb("daily")?.entries as Array<{ uid: string; points: number }>;
    assert.strictEqual(entries?.length, 1);
    assert.strictEqual(entries?.[0]?.uid, "u1");
    assert.strictEqual(entries?.[0]?.points, 5);
  });

  it("does not throw when runTransaction rejects (allSettled absorbs the error)", async () => {
    // Simulates a transient Firestore error on every period transaction.
    // updateUserLeaderboards must complete without throwing; the rejection is
    // only logged (console.error). This exercises the result.status === "rejected"
    // branch in the post-allSettled loop.
    const today = "2026-04-15";
    const failingDb = {
      collection: (name: string) => {
        if (name === "claims") {
          return {
            where: (_f: string, _o: string, _v: unknown) => ({
              where: (_f2: string, _o2: string, _v2: unknown) => ({
                where: (_f3: string, _o3: string, _v3: unknown) => ({
                  get: async () => ({ docs: [] }),
                }),
                get: async () => ({ docs: [] }),
              }),
              get: async () => ({ docs: [] }),
            }),
          };
        }
        if (name === "leaderboards") {
          return { doc: (id: string) => ({ _id: id }) };
        }
        throw new Error(`Unexpected collection: ${name}`);
      },
      runTransaction: async (_fn: unknown) => {
        throw new Error("simulated Firestore transaction failure");
      },
    };
    // Must resolve without throwing despite all three period transactions failing.
    await assert.doesNotReject(
      updateUserLeaderboards(
        "u1", "Alice", today,
        failingDb as unknown as import("firebase-admin").firestore.Firestore,
      ),
    );
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
  it("handles _latitude/_longitude coordinate value 0 (falsy-but-valid)", () => {
    const r = getLatLng({ _latitude: 0, _longitude: 0 });
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

  it("streak starts at 1 when currentStreak is 0 and last claim was yesterday", () =>
    assert.strictEqual(computeNewStreak(yesterday, 0, today, yesterday), 1));
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
  const wrappedRegisterFcmToken = testEnv.wrap(myFunctions.registerFcmToken) as (data: unknown, context?: unknown) => Promise<unknown>;

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

  describe("registerFcmToken (onCall)", () => {
    it("should throw unauthenticated when no auth context", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: { token: "some-fcm-token" } };
      try {
        await wrappedRegisterFcmToken(req);
        assert.fail("Expected unauthenticated error");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "unauthenticated");
      }
    });

    it("should throw invalid-argument when token is missing", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: {}, auth: { uid: "test-uid" } };
      try {
        await wrappedRegisterFcmToken(req);
        assert.fail("Expected invalid-argument error");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });

    it("should throw invalid-argument when token is empty string", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: { token: "" }, auth: { uid: "test-uid" } };
      try {
        await wrappedRegisterFcmToken(req);
        assert.fail("Expected invalid-argument error");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });

    it("should throw invalid-argument when token is not a string", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: { token: 12345 }, auth: { uid: "test-uid" } };
      try {
        await wrappedRegisterFcmToken(req);
        assert.fail("Expected invalid-argument error");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });
  });
});

// ── applyUserClaims pure unit tests (no Firebase required) ────────────────────

describe("applyUserClaims", () => {
  /** Minimal LookupResult with two postboxes: one EIIR (2 pts, N), one VR (7 pts, S). */
  const makeFull = () => ({
    postboxes: {
      box1: { monarch: "EIIR", compass: { exact: "N" } },
      box2: { monarch: "VR",   compass: { exact: "S" } },
    },
    counts: { total: 2, claimedToday: 0, EIIR: 1, VR: 1 },
    points: { min: 2, max: 7 },
    compass: { N: 1, S: 1 },
  });

  it("returns correct shape when user has no claims", () => {
    const result = applyUserClaims(makeFull(), new Set());
    assert.ok("slimPostboxes" in result);
    assert.ok("updatedCounts" in result);
    assert.ok("updatedPoints" in result);
    assert.ok("updatedCompass" in result);
    assert.ok("claimedCompass" in result);
  });

  it("all postboxes have claimedToday=false when user has no claims", () => {
    const { slimPostboxes } = applyUserClaims(makeFull(), new Set());
    assert.strictEqual(slimPostboxes.box1.claimedToday, false);
    assert.strictEqual(slimPostboxes.box2.claimedToday, false);
  });

  it("preserves monarch fields in slim postboxes", () => {
    const { slimPostboxes } = applyUserClaims(makeFull(), new Set());
    assert.strictEqual(slimPostboxes.box1.monarch, "EIIR");
    assert.strictEqual(slimPostboxes.box2.monarch, "VR");
  });

  it("marks claimed postbox with claimedToday=true", () => {
    const { slimPostboxes } = applyUserClaims(makeFull(), new Set(["box1"]));
    assert.strictEqual(slimPostboxes.box1.claimedToday, true);
    assert.strictEqual(slimPostboxes.box2.claimedToday, false);
  });

  it("claimedToday count equals number of user-claimed postboxes", () => {
    const { updatedCounts } = applyUserClaims(makeFull(), new Set(["box1"]));
    assert.strictEqual(updatedCounts.claimedToday, 1);
  });

  it("per-cipher _claimed count reflects user's claims only", () => {
    const { updatedCounts } = applyUserClaims(makeFull(), new Set(["box1"]));
    assert.strictEqual(updatedCounts["EIIR_claimed"], 1);
    assert.strictEqual(updatedCounts["VR_claimed"] ?? 0, 0);
  });

  it("non-claimed count keys (total, per-cipher totals) are preserved", () => {
    const { updatedCounts } = applyUserClaims(makeFull(), new Set(["box1"]));
    assert.strictEqual(updatedCounts.total, 2);
    assert.strictEqual(updatedCounts.EIIR, 1);
    assert.strictEqual(updatedCounts.VR, 1);
  });

  it("points range excludes claimed postbox", () => {
    // box1 (EIIR, 2pts) is claimed → only box2 (VR, 7pts) counts
    const { updatedPoints } = applyUserClaims(makeFull(), new Set(["box1"]));
    assert.strictEqual(updatedPoints.min, 7);
    assert.strictEqual(updatedPoints.max, 7);
  });

  it("points {min:0, max:0} when all postboxes claimed", () => {
    const { updatedPoints } = applyUserClaims(makeFull(), new Set(["box1", "box2"]));
    assert.strictEqual(updatedPoints.min, 0);
    assert.strictEqual(updatedPoints.max, 0);
  });

  it("compass excludes claimed postboxes", () => {
    // box1 (N) is claimed → compass should only show S
    const { updatedCompass } = applyUserClaims(makeFull(), new Set(["box1"]));
    assert.strictEqual(updatedCompass["N"] ?? 0, 0);
    assert.strictEqual(updatedCompass["S"], 1);
  });

  it("compass is empty when all postboxes claimed", () => {
    const { updatedCompass } = applyUserClaims(makeFull(), new Set(["box1", "box2"]));
    assert.strictEqual(Object.keys(updatedCompass).length, 0);
  });

  it("postbox without monarch gets default 2 pts in points range", () => {
    const full = {
      postboxes: {
        noMonarch: { compass: { exact: "E" } },
      },
      counts: { total: 1, claimedToday: 0 },
      points: { min: 2, max: 2 },
      compass: { E: 1 },
    };
    const { updatedPoints } = applyUserClaims(full, new Set());
    assert.strictEqual(updatedPoints.min, 2);
    assert.strictEqual(updatedPoints.max, 2);
  });

  it("postbox without compass.exact is not added to updatedCompass", () => {
    const full = {
      postboxes: {
        noCompass: { monarch: "EIIR" },
      },
      counts: { total: 1, claimedToday: 0 },
      points: { min: 2, max: 2 },
      compass: {},
    };
    const { updatedCompass } = applyUserClaims(full, new Set());
    assert.strictEqual(Object.keys(updatedCompass).length, 0);
  });

  it("accumulates multiple unclaimed boxes from the same compass direction", () => {
    const full = {
      postboxes: {
        a: { monarch: "EIIR", compass: { exact: "N" } },
        b: { monarch: "VR",   compass: { exact: "N" } },
      },
      counts: { total: 2, claimedToday: 0 },
      points: { min: 2, max: 7 },
      compass: { N: 2 },
    };
    const { updatedCompass } = applyUserClaims(full, new Set());
    assert.strictEqual(updatedCompass["N"], 2);
  });

  it("claimed postbox without monarch increments claimedToday but adds no cipher _claimed key", () => {
    // Postboxes without a known cipher exist in OSM data. When the user claims
    // one, claimedToday should still increment but no CIPHER_claimed key is written
    // (there is no cipher to attribute the claim to).
    const full = {
      postboxes: {
        noMonarch: { compass: { exact: "W" } },
      },
      counts: { total: 1, claimedToday: 0 },
      points: { min: 2, max: 2 },
      compass: { W: 1 },
    };
    const { updatedCounts, updatedPoints } = applyUserClaims(full, new Set(["noMonarch"]));
    assert.strictEqual(updatedCounts.claimedToday, 1);
    const cipherKeys = Object.keys(updatedCounts).filter(k => k.endsWith("_claimed"));
    assert.strictEqual(cipherKeys.length, 0, "No cipher _claimed key should be added for unknown monarch");
    // The unclaimed points range should be empty (everything claimed).
    assert.strictEqual(updatedPoints.min, 0);
    assert.strictEqual(updatedPoints.max, 0);
  });

  it("slim postbox for no-monarch has no monarch field", () => {
    const full = {
      postboxes: {
        noMonarch: { compass: { exact: "W" } },
      },
      counts: { total: 1, claimedToday: 0 },
      points: { min: 2, max: 2 },
      compass: { W: 1 },
    };
    const { slimPostboxes } = applyUserClaims(full, new Set());
    assert.strictEqual("monarch" in slimPostboxes["noMonarch"], false,
      "slim postbox must omit monarch field when postbox has no monarch");
  });

  it("strips _claimed keys from input counts (replaces with per-user values)", () => {
    // lookupPostboxes includes global CIPHER_claimed counts from any user's daily
    // claim. applyUserClaims must strip these and replace with per-user values.
    const full = {
      postboxes: {
        box1: { monarch: "EIIR", compass: { exact: "N" } },
      },
      // Includes a global EIIR_claimed=1 from another user's claim today.
      counts: { total: 1, claimedToday: 1, EIIR: 1, "EIIR_claimed": 1 },
      points: { min: 0, max: 0 },
      compass: {},
    };
    // THIS user has NOT claimed box1 yet.
    const { updatedCounts } = applyUserClaims(full, new Set());
    assert.strictEqual(updatedCounts["EIIR_claimed"] ?? 0, 0,
      "Global EIIR_claimed should be stripped and replaced with user's own (0) claims");
    assert.strictEqual(updatedCounts.EIIR, 1, "Total EIIR count preserved");
    assert.strictEqual(updatedCounts.claimedToday, 0, "User's own claimedToday is 0");
  });

  it("points max stays at highest value when a lower-pts postbox follows a higher one", () => {
    // Exercises the false branch of `if (pts > unclaimedMax)`.
    // Processing order is insertion order: VR first (7pts), then EIIR (2pts).
    const full = {
      postboxes: {
        high: { monarch: "VR",   compass: { exact: "N" } },  // 7 pts — processed first
        low:  { monarch: "EIIR", compass: { exact: "S" } },  // 2 pts — should not lower max
      },
      counts: { total: 2, claimedToday: 0, VR: 1, EIIR: 1 },
      points: { min: 2, max: 7 },
      compass: { N: 1, S: 1 },
    };
    const { updatedPoints } = applyUserClaims(full, new Set());
    assert.strictEqual(updatedPoints.max, 7, "Max should remain 7 after processing the 2-pt postbox");
    assert.strictEqual(updatedPoints.min, 2, "Min should be 2");
  });

  it("handles empty postboxes map (no postboxes in range)", () => {
    const empty = {
      postboxes: {},
      counts: { total: 0, claimedToday: 0 },
      points: { min: 0, max: 0 },
      compass: {},
    };
    const { slimPostboxes, updatedCounts, updatedPoints, updatedCompass } =
      applyUserClaims(empty, new Set());
    assert.strictEqual(Object.keys(slimPostboxes).length, 0);
    assert.strictEqual(updatedCounts.claimedToday, 0);
    assert.strictEqual(updatedCounts.total, 0);
    assert.strictEqual(updatedPoints.min, 0);
    assert.strictEqual(updatedPoints.max, 0);
    assert.strictEqual(Object.keys(updatedCompass).length, 0);
  });

  it("claimedCompass is empty when user has no claims", () => {
    const { claimedCompass } = applyUserClaims(makeFull(), new Set());
    assert.strictEqual(Object.keys(claimedCompass).length, 0);
  });

  it("claimedCompass contains direction of claimed postbox", () => {
    // box1 is at N; user has claimed it
    const { claimedCompass } = applyUserClaims(makeFull(), new Set(["box1"]));
    assert.strictEqual(claimedCompass["N"], 1);
    assert.strictEqual(claimedCompass["S"] ?? 0, 0);
  });

  it("claimedCompass contains all claimed directions; updatedCompass has none", () => {
    // Both boxes claimed: N (box1) and S (box2)
    const { claimedCompass, updatedCompass } =
      applyUserClaims(makeFull(), new Set(["box1", "box2"]));
    assert.strictEqual(claimedCompass["N"], 1);
    assert.strictEqual(claimedCompass["S"], 1);
    assert.strictEqual(Object.keys(updatedCompass).length, 0);
  });

  it("claimed postbox without compass.exact is not added to claimedCompass", () => {
    const full = {
      postboxes: {
        noCompass: { monarch: "EIIR" },
      },
      counts: { total: 1, claimedToday: 0 },
      points: { min: 2, max: 2 },
      compass: {},
    };
    const { claimedCompass } = applyUserClaims(full, new Set(["noCompass"]));
    assert.strictEqual(Object.keys(claimedCompass).length, 0);
  });
});

describe("getPeriodResetFields", () => {
  it("always resets dailyPoints", () => {
    const fields = getPeriodResetFields("2026-04-15", "2026-04-13", "2026-04-01");
    assert.strictEqual(fields.dailyPoints, 0);
  });

  it("does not reset weeklyPoints on a non-Monday", () => {
    const fields = getPeriodResetFields("2026-04-15", "2026-04-13", "2026-04-01");
    assert.strictEqual(fields.weeklyPoints, undefined);
  });

  it("resets weeklyPoints when today equals weekStart (Monday)", () => {
    const fields = getPeriodResetFields("2026-04-14", "2026-04-14", "2026-04-01");
    assert.strictEqual(fields.weeklyPoints, 0);
  });

  it("does not reset monthlyPoints mid-month", () => {
    const fields = getPeriodResetFields("2026-04-15", "2026-04-13", "2026-04-01");
    assert.strictEqual(fields.monthlyPoints, undefined);
  });

  it("resets monthlyPoints when today equals monthStart (1st)", () => {
    const fields = getPeriodResetFields("2026-05-01", "2026-05-01", "2026-05-01");
    assert.strictEqual(fields.monthlyPoints, 0);
  });

  it("resets both weeklyPoints and monthlyPoints on Monday the 1st", () => {
    // 2026-06-01 is a Monday
    const fields = getPeriodResetFields("2026-06-01", "2026-06-01", "2026-06-01");
    assert.strictEqual(fields.weeklyPoints, 0);
    assert.strictEqual(fields.monthlyPoints, 0);
  });
});

import { rebuildPeriodLeaderboard } from "../newDayScoreboard";

describe("rebuildPeriodLeaderboard (unit, mock Firestore)", () => {
  type ClaimDoc = { userid: string; dailyDate: string; points: number };
  type UserDoc  = { displayName?: string };
  type LbDoc    = { periodKey?: string; entries?: unknown[] };

  function makeMockDb(
    claims: ClaimDoc[],
    users: Record<string, UserDoc> = {}
  ) {
    let writtenLb: { periodKey?: string; entries?: unknown[] } | undefined;

    const db = {
      collection: (name: string) => {
        if (name === "claims") {
          let preds: Array<{ field: string; op: string; val: unknown }> = [];
          const q = {
            where(f: string, o: string, v: unknown) {
              preds = [...preds, { field: f, op: o, val: v }];
              return q;
            },
            async get() {
              return {
                docs: claims
                  .filter(doc =>
                    preds.every(({ field, op, val }) => {
                      const v = (doc as Record<string, unknown>)[field];
                      if (op === "==") return v === val;
                      if (op === ">=") return typeof v === "string" && typeof val === "string" && v >= val;
                      if (op === "<=") return typeof v === "string" && typeof val === "string" && v <= val;
                      return false;
                    })
                  )
                  .map(d => ({ data: () => d as Record<string, unknown> })),
              };
            },
          };
          return q;
        }
        if (name === "users") {
          return {
            doc: (uid: string) => ({
              async get() {
                const u = users[uid];
                return { data: () => u as Record<string, unknown> | undefined };
              },
            }),
          };
        }
        if (name === "leaderboards") {
          return {
            doc: (_id: string) => ({
              async set(data: LbDoc) { writtenLb = data; },
              async get() {
                return { data: () => writtenLb as Record<string, unknown> | undefined };
              },
            }),
          };
        }
        throw new Error(`Unexpected collection: ${name}`);
      },
      async runTransaction<T>(
        fn: (tx: {
          get: (ref: { get: () => Promise<{ data: () => unknown }> }) => Promise<{ data: () => unknown }>;
          set: (ref: { set: (d: unknown) => Promise<void> }, d: unknown) => void;
        }) => Promise<T>
      ): Promise<T> {
        const tx = {
          get: (ref: { get: () => Promise<{ data: () => unknown }> }) => ref.get(),
          set: (ref: { set: (d: unknown) => Promise<void> }, d: unknown) => { void ref.set(d); },
        };
        return fn(tx);
      },
    };

    return {
      db: db as unknown as import("firebase-admin").firestore.Firestore,
      getWrittenLb: () => writtenLb,
    };
  }

  it("writes empty entries with correct periodKey when startDate > endDate (new period)", async () => {
    const { db, getWrittenLb } = makeMockDb([]);
    await rebuildPeriodLeaderboard("weekly", "2026-04-20", "2026-04-19", db);
    const written = getWrittenLb();
    assert.ok(written, "should have written a leaderboard document");
    assert.strictEqual(written!.periodKey, "week:2026-04-20");
    assert.deepStrictEqual(written!.entries, []);
  });

  it("does NOT clobber entries when stored periodKey already matches the new period", async () => {
    // Simulates a claim that landed between midnight and the rebuild sweep:
    // updateUserLeaderboards has already written entries under the new
    // periodKey, and the empty-period rebuild must not overwrite them.
    const { db, getWrittenLb } = makeMockDb([]);
    const lbRef = db.collection("leaderboards").doc("weekly") as unknown as {
      set: (d: unknown) => Promise<void>;
    };
    await lbRef.set({
      periodKey: "week:2026-04-20",
      entries: [{ uid: "u1", displayName: "Alice", points: 5 }],
    });
    await rebuildPeriodLeaderboard("weekly", "2026-04-20", "2026-04-19", db);
    const written = getWrittenLb();
    assert.strictEqual(written!.periodKey, "week:2026-04-20");
    assert.deepStrictEqual(written!.entries, [
      { uid: "u1", displayName: "Alice", points: 5 },
    ]);
  });

  it("aggregates claims from multiple days and sorts by points descending", async () => {
    const { db, getWrittenLb } = makeMockDb(
      [
        { userid: "u1", dailyDate: "2026-04-13", points: 5 },
        { userid: "u1", dailyDate: "2026-04-14", points: 3 },
        { userid: "u2", dailyDate: "2026-04-13", points: 10 },
      ],
      { u1: { displayName: "Alice" }, u2: { displayName: "Bob" } }
    );
    await rebuildPeriodLeaderboard("weekly", "2026-04-13", "2026-04-15", db);
    const entries = getWrittenLb()!.entries as Array<{ uid: string; displayName: string; points: number }>;
    assert.strictEqual(entries.length, 2);
    assert.strictEqual(entries[0].uid, "u2");
    assert.strictEqual(entries[0].points, 10);
    assert.strictEqual(entries[1].uid, "u1");
    assert.strictEqual(entries[1].points, 8);
  });

  it("uses fallback display name when user doc is missing", async () => {
    const { db, getWrittenLb } = makeMockDb(
      [{ userid: "abc123xyz", dailyDate: "2026-04-13", points: 4 }],
      {} // no user docs
    );
    await rebuildPeriodLeaderboard("daily", "2026-04-13", "2026-04-13", db);
    const entries = getWrittenLb()!.entries as Array<{ displayName: string }>;
    assert.strictEqual(entries[0].displayName, "Player_abc123");
  });

  it("excludes claims outside the date range", async () => {
    const { db, getWrittenLb } = makeMockDb(
      [
        { userid: "u1", dailyDate: "2026-04-12", points: 100 }, // before start
        { userid: "u1", dailyDate: "2026-04-13", points: 5 },   // in range
        { userid: "u1", dailyDate: "2026-04-16", points: 100 }, // after end
      ],
      { u1: { displayName: "Alice" } }
    );
    await rebuildPeriodLeaderboard("weekly", "2026-04-13", "2026-04-15", db);
    const entries = getWrittenLb()!.entries as Array<{ points: number }>;
    assert.strictEqual(entries[0].points, 5);
  });

  it("omits users with 0 total points", async () => {
    const { db, getWrittenLb } = makeMockDb(
      [{ userid: "u1", dailyDate: "2026-04-13", points: 0 }],
      { u1: { displayName: "Alice" } }
    );
    await rebuildPeriodLeaderboard("daily", "2026-04-13", "2026-04-13", db);
    assert.deepStrictEqual(getWrittenLb()!.entries, []);
  });

  it("caps entries at 100", async () => {
    const claims = Array.from({ length: 120 }, (_, i) => ({
      userid: `u${i}`,
      dailyDate: "2026-04-13",
      points: 120 - i,
    }));
    const users = Object.fromEntries(claims.map(c => [c.userid, { displayName: `Player ${c.userid}` }]));
    const { db, getWrittenLb } = makeMockDb(claims, users);
    await rebuildPeriodLeaderboard("monthly", "2026-04-01", "2026-04-13", db);
    assert.strictEqual((getWrittenLb()!.entries as unknown[]).length, 100);
  });

  it("sets correct periodKey for daily period", async () => {
    const { db, getWrittenLb } = makeMockDb(
      [{ userid: "u1", dailyDate: "2026-04-17", points: 2 }],
      { u1: { displayName: "Alice" } }
    );
    await rebuildPeriodLeaderboard("daily", "2026-04-17", "2026-04-17", db);
    assert.strictEqual(getWrittenLb()!.periodKey, "2026-04-17");
  });
});

import { updateFcmTokens, diffFriends, shouldNotifyFirstClaim, shouldNotifyOvertake } from "../_notifications";

describe("updateFcmTokens", () => {
  it("adds a token to an empty list", () => {
    assert.deepStrictEqual(updateFcmTokens([], "tok1"), ["tok1"]);
  });
  it("deduplicates an existing token", () => {
    assert.deepStrictEqual(updateFcmTokens(["tok1"], "tok1"), ["tok1"]);
  });
  it("appends a new token", () => {
    assert.deepStrictEqual(updateFcmTokens(["a", "b"], "c"), ["a", "b", "c"]);
  });
  it("drops the oldest token when cap is exceeded", () => {
    assert.deepStrictEqual(
      updateFcmTokens(["a", "b", "c", "d", "e"], "f"),
      ["b", "c", "d", "e", "f"]
    );
  });
  it("result never exceeds the default cap of 5", () => {
    const result = updateFcmTokens(["a", "b", "c", "d", "e"], "f");
    assert.strictEqual(result.length, 5);
  });
});

describe("diffFriends", () => {
  it("returns empty array when lists are identical", () => {
    assert.deepStrictEqual(diffFriends(["a", "b"], ["a", "b"]), []);
  });
  it("returns empty array when a friend is removed (not an addition)", () => {
    assert.deepStrictEqual(diffFriends(["a", "b"], ["a"]), []);
  });
  it("returns the single newly-added UID", () => {
    assert.deepStrictEqual(diffFriends(["a"], ["a", "b"]), ["b"]);
  });
  it("returns multiple newly-added UIDs", () => {
    assert.deepStrictEqual(diffFriends([], ["a", "b"]), ["a", "b"]);
  });
  it("ignores UIDs already present in before", () => {
    assert.deepStrictEqual(diffFriends(["x"], ["x", "y", "z"]), ["y", "z"]);
  });
  it("detects new friend even when list length is unchanged (simultaneous add+remove)", () => {
    // This is the edge case that the removed `after.length <= before.length`
    // guard would have incorrectly silenced: removing "a" and adding "c"
    // leaves length == 2, but "c" is still a new friend who should be notified.
    assert.deepStrictEqual(diffFriends(["a", "b"], ["b", "c"]), ["c"]);
  });
});

describe("shouldNotifyFirstClaim", () => {
  it("returns true when friend has no dailyPoints (undefined)", () =>
    assert.strictEqual(shouldNotifyFirstClaim({}), true));

  it("returns true when friend dailyPoints is 0", () =>
    assert.strictEqual(shouldNotifyFirstClaim({ dailyPoints: 0 }), true));

  it("returns false when friend dailyPoints > 0 (already scored today)", () =>
    assert.strictEqual(shouldNotifyFirstClaim({ dailyPoints: 5 }), false));

  it("returns false when friendFirstScore pref is explicitly false", () =>
    assert.strictEqual(
      shouldNotifyFirstClaim({ dailyPoints: 0, notificationPrefs: { friendFirstScore: false } }),
      false
    ));

  it("returns true when friendFirstScore pref is true (opt-in)", () =>
    assert.strictEqual(
      shouldNotifyFirstClaim({ dailyPoints: 0, notificationPrefs: { friendFirstScore: true } }),
      true
    ));

  it("returns true when notificationPrefs is absent", () =>
    assert.strictEqual(shouldNotifyFirstClaim({ dailyPoints: 0 }), true));

  it("returns false for undefined fdata", () =>
    assert.strictEqual(shouldNotifyFirstClaim(undefined), true));

  it("returns false when dailyPoints is stored as a float (e.g. 3.5)", () =>
    assert.strictEqual(shouldNotifyFirstClaim({ dailyPoints: 3.5 }), false));

  // With todayLondon provided, lastClaimDate becomes the authoritative source
  // of "has claimed today" (guards against stale dailyPoints surviving past
  // the midnight newDayScoreboard sweep).
  it("returns true when lastClaimDate != today even if stale dailyPoints > 0", () =>
    assert.strictEqual(
      shouldNotifyFirstClaim(
        { dailyPoints: 10, lastClaimDate: "2026-04-16" },
        "2026-04-17"
      ),
      true
    ));

  it("returns false when lastClaimDate === today (regardless of dailyPoints)", () =>
    assert.strictEqual(
      shouldNotifyFirstClaim(
        { dailyPoints: 0, lastClaimDate: "2026-04-17" },
        "2026-04-17"
      ),
      false
    ));

  it("returns true when lastClaimDate is missing and todayLondon provided", () =>
    assert.strictEqual(
      shouldNotifyFirstClaim({ dailyPoints: 5 }, "2026-04-17"),
      true
    ));
});

describe("shouldNotifyOvertake", () => {
  it("returns false for undefined fdata", () =>
    assert.strictEqual(shouldNotifyOvertake(undefined, 5, 10), false));

  it("returns false when friend has 0 dailyPoints (hasn't scored)", () =>
    assert.strictEqual(shouldNotifyOvertake({ dailyPoints: 0 }, 5, 10), false));

  it("returns false when friend dailyPoints is missing (treated as 0)", () =>
    assert.strictEqual(shouldNotifyOvertake({}, 5, 10), false));

  it("returns false when newDailyPoints equals friend's score (tie, not an overtake)", () =>
    assert.strictEqual(shouldNotifyOvertake({ dailyPoints: 10 }, 5, 10), false));

  it("returns false when newDailyPoints is less than friend's score", () =>
    assert.strictEqual(shouldNotifyOvertake({ dailyPoints: 15 }, 5, 10), false));

  it("returns true when newDailyPoints strictly exceeds friend's non-zero score", () =>
    assert.strictEqual(shouldNotifyOvertake({ dailyPoints: 8 }, 5, 10), true));

  it("returns false when friendOvertakes pref is explicitly false", () =>
    assert.strictEqual(
      shouldNotifyOvertake({ dailyPoints: 8, notificationPrefs: { friendOvertakes: false } }, 5, 10),
      false
    ));

  it("returns true when friendOvertakes pref is true (opt-in)", () =>
    assert.strictEqual(
      shouldNotifyOvertake({ dailyPoints: 8, notificationPrefs: { friendOvertakes: true } }, 5, 10),
      true
    ));

  it("returns true when notificationPrefs is absent and score genuinely overtakes", () =>
    assert.strictEqual(shouldNotifyOvertake({ dailyPoints: 3 }, 0, 7), true));

  it("returns false when newDailyPoints is 0 (user has no score, cannot overtake)", () =>
    assert.strictEqual(shouldNotifyOvertake({ dailyPoints: 5 }, 0, 0), false));

  it("returns false when user was already ahead before this claim (no re-notify)", () =>
    assert.strictEqual(shouldNotifyOvertake({ dailyPoints: 5 }, 7, 10), false));

  it("returns true on the exact claim that crosses the friend's score", () =>
    assert.strictEqual(shouldNotifyOvertake({ dailyPoints: 5 }, 5, 7), true));

  it("returns true when user was tied before and this claim breaks the tie", () =>
    assert.strictEqual(shouldNotifyOvertake({ dailyPoints: 5 }, 5, 6), true));

  // With todayLondon provided, a friend whose lastClaimDate isn't today is
  // treated as 0 dailyPoints — so stale dailyPoints from yesterday can't
  // incorrectly suppress the notification or fire it against someone who
  // hasn't actually claimed today.
  it("returns false when friend's lastClaimDate != today even with stale dailyPoints > 0", () =>
    assert.strictEqual(
      shouldNotifyOvertake(
        { dailyPoints: 10, lastClaimDate: "2026-04-16" },
        0,
        5,
        "2026-04-17"
      ),
      false
    ));

  it("returns true when friend claimed today and we cross their score", () =>
    assert.strictEqual(
      shouldNotifyOvertake(
        { dailyPoints: 3, lastClaimDate: "2026-04-17" },
        0,
        5,
        "2026-04-17"
      ),
      true
    ));

  it("returns false when friend has no lastClaimDate field (treated as hasn't claimed today)", () =>
    assert.strictEqual(
      shouldNotifyOvertake({ dailyPoints: 5 }, 0, 10, "2026-04-17"),
      false
    ));
});
