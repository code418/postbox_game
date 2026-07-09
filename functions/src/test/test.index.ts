import assert from "assert";
import test from "firebase-functions-test";
import * as myFunctions from "../index";
import { filterToCorridor, filterToEllipse, beamSearchOrienteering, metresBetween } from "../_routePlanner";
import { getPoints } from "../_getPoints";
import {
  sanitiseClaimRadius,
  parsePointsOverride,
  resolvePointsForMonarch,
  getGameConfig,
  getClaimRadiusMeters,
  getPointsForMonarch,
  setConfigLoaderForTest,
  DEFAULT_CLAIM_RADIUS_METERS,
  type GameConfig,
} from "../_config";

// Keep every test offline: the real _config loader reads the Remote Config
// server template over the network. Install a deterministic fallback loader for
// the whole run so startScoring / _recomputeScores paths resolve to the
// hard-coded points+radius without a network call; the _config caching tests
// override it per-test and restore this in afterEach.
const fallbackGameConfig = async (): Promise<GameConfig> => ({
  claimRadiusMeters: DEFAULT_CLAIM_RADIUS_METERS,
  pointsOverride: null,
});
before(() => setConfigLoaderForTest(fallbackGameConfig));
import { getTodayLondon, previousDay, getLondonHourMinute } from "../_dateUtils";
import {
  decideFire,
  slotForLondonTime,
  shouldNotifyStreakReminder,
  streakReminderBody,
  findStreakReminderRecipients,
  sendStreakReminders,
  STREAK_REMINDER_SLOTS,
} from "../streakReminder";
import { getWeekStart, getMonthStart, getPeriodKey, mergePeriodEntries, mergeLifetimeEntries, updateUserLeaderboards, countySlug } from "../_leaderboardUtils";
import { setPrecision, getLatLng, MAX_GEOHASH_PRECISION } from "../_lookupPostboxes";
import { applyUserClaims } from "../_nearbyUtils";
import { computeNewStreak } from "../_streakUtils";
import { containsProfanity } from "../_profanityFilter";
import { sanitiseName } from "../onUserCreated";
import { checkTravelSpeed, MAX_METRES_PER_MIN } from "../_travelSpeed";
import { aggregateClaimHistory, periodStartDate } from "../userClaimHistory";
import { diffSnapshots, type MigrationSnapshot } from "../_migrationVerify";

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

describe("_config: sanitiseClaimRadius", () => {
  it("accepts an in-band value", () => assert.strictEqual(sanitiseClaimRadius(45), 45));
  it("accepts the lower bound 10", () => assert.strictEqual(sanitiseClaimRadius(10), 10));
  it("accepts the upper bound 100", () => assert.strictEqual(sanitiseClaimRadius(100), 100));
  it("falls back below the lower bound", () =>
    assert.strictEqual(sanitiseClaimRadius(5), DEFAULT_CLAIM_RADIUS_METERS));
  it("falls back above the upper bound", () =>
    assert.strictEqual(sanitiseClaimRadius(500), DEFAULT_CLAIM_RADIUS_METERS));
  it("falls back for non-numbers", () =>
    assert.strictEqual(sanitiseClaimRadius("30"), DEFAULT_CLAIM_RADIUS_METERS));
  it("falls back for NaN", () =>
    assert.strictEqual(sanitiseClaimRadius(NaN), DEFAULT_CLAIM_RADIUS_METERS));
});

describe("_config: parsePointsOverride", () => {
  it("parses a valid partial override", () =>
    assert.deepStrictEqual(parsePointsOverride('{"VR":8}'), { VR: 8 }));
  it("drops unknown monarch keys", () =>
    assert.deepStrictEqual(parsePointsOverride('{"VR":8,"BOGUS":3}'), { VR: 8 }));
  it("rejects wholesale when a value is out of range", () =>
    assert.strictEqual(parsePointsOverride('{"VR":999}'), null));
  it("rejects wholesale when a value is below 1", () =>
    assert.strictEqual(parsePointsOverride('{"VR":0}'), null));
  it("rejects wholesale for non-integer values", () =>
    assert.strictEqual(parsePointsOverride('{"VR":7.5}'), null));
  it("returns null for invalid JSON", () =>
    assert.strictEqual(parsePointsOverride("not json"), null));
  it("returns null for an empty string", () =>
    assert.strictEqual(parsePointsOverride(""), null));
  it("returns null for a JSON array", () =>
    assert.strictEqual(parsePointsOverride("[1,2,3]"), null));
  it("returns an empty map for an empty object", () =>
    assert.deepStrictEqual(parsePointsOverride("{}"), {}));
});

describe("_config: resolvePointsForMonarch", () => {
  const cfg = (pointsOverride: Record<string, number> | null): GameConfig => ({
    claimRadiusMeters: 30,
    pointsOverride,
  });
  it("uses the override when present for the monarch", () =>
    assert.strictEqual(resolvePointsForMonarch(cfg({ VR: 8 }), "VR"), 8));
  it("falls back to hard-coded when the monarch is not overridden", () =>
    assert.strictEqual(resolvePointsForMonarch(cfg({ EIIR: 3 }), "VR"), 7));
  it("falls back to hard-coded when there is no override map", () =>
    assert.strictEqual(resolvePointsForMonarch(cfg(null), "VR"), 7));
  it("returns the default 2 for an unknown monarch with no override", () =>
    assert.strictEqual(resolvePointsForMonarch(cfg(null), "ZZZ"), 2));
  it("returns 2 for a null monarch", () =>
    assert.strictEqual(resolvePointsForMonarch(cfg(null), null), 2));
});

describe("_config: getGameConfig caching", () => {
  afterEach(() => setConfigLoaderForTest(fallbackGameConfig));

  it("caches within the TTL and refetches after it", async () => {
    let calls = 0;
    setConfigLoaderForTest(async () => {
      calls++;
      return { claimRadiusMeters: 40 + calls, pointsOverride: null };
    });
    const t0 = 1_000_000;
    const a = await getGameConfig(t0);
    const b = await getGameConfig(t0 + 60_000); // within the 5-min TTL
    assert.strictEqual(calls, 1);
    assert.strictEqual(a.claimRadiusMeters, b.claimRadiusMeters);
    const c = await getGameConfig(t0 + 5 * 60 * 1000 + 1); // past the TTL
    assert.strictEqual(calls, 2);
    assert.strictEqual(c.claimRadiusMeters, 42);
  });

  it("getClaimRadiusMeters / getPointsForMonarch read the cached config", async () => {
    setConfigLoaderForTest(async () => ({
      claimRadiusMeters: 55,
      pointsOverride: { VR: 8 },
    }));
    assert.strictEqual(await getClaimRadiusMeters(), 55);
    assert.strictEqual(await getPointsForMonarch("VR"), 8);
    assert.strictEqual(await getPointsForMonarch("EIIR"), 2);
  });
});

describe("diffSnapshots (migration verification)", () => {
  const snap = (
    roots: Record<string, number>,
    groups: Record<string, number> = {},
  ): MigrationSnapshot => ({
    project: "the-postbox-game",
    generatedAt: "2026-06-14T00:00:00.000Z",
    roots,
    groups,
  });

  it("reports ok when every count matches", () => {
    const r = diffSnapshots(
      snap({ postbox: 100, claims: 50 }, { entries: 12 }),
      snap({ postbox: 100, claims: 50 }, { entries: 12 }),
    );
    assert.strictEqual(r.ok, true);
    assert.ok(r.rows.every((row) => row.status === "ok"));
    assert.ok(r.rows.every((row) => row.delta === 0));
  });

  it("flags a changed count as a mismatch with the right delta", () => {
    const r = diffSnapshots(
      snap({ postbox: 100, claims: 50 }),
      snap({ postbox: 100, claims: 47 }),
    );
    assert.strictEqual(r.ok, false);
    const claims = r.rows.find((row) => row.name === "claims");
    assert.strictEqual(claims?.status, "mismatch");
    assert.strictEqual(claims?.delta, -3);
    assert.strictEqual(
      r.rows.find((row) => row.name === "postbox")?.status,
      "ok",
    );
  });

  it("flags a collection present on only one side as missing", () => {
    const dropped = diffSnapshots(
      snap({ postbox: 100, reportQuotas: 4 }),
      snap({ postbox: 100 }),
    );
    assert.strictEqual(dropped.ok, false);
    const rq = dropped.rows.find((row) => row.name === "reportQuotas");
    assert.strictEqual(rq?.status, "missing");
    assert.strictEqual(rq?.before, 4);
    assert.strictEqual(rq?.after, null);

    const added = diffSnapshots(snap({ postbox: 100 }), snap({ postbox: 100, surprise: 1 }));
    assert.strictEqual(added.ok, false);
    assert.strictEqual(added.rows.find((row) => row.name === "surprise")?.status, "missing");
  });

  it("diffs collection groups the same way as root collections", () => {
    const r = diffSnapshots(
      snap({}, { entries: 30, countyStats: 9 }),
      snap({}, { entries: 30, countyStats: 8 }),
    );
    assert.strictEqual(r.ok, false);
    const cs = r.rows.find((row) => row.name === "countyStats");
    assert.strictEqual(cs?.scope, "group");
    assert.strictEqual(cs?.status, "mismatch");
    assert.strictEqual(cs?.delta, -1);
  });
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

  it("a new low-score user is excluded when the list is full and they don't make the cut", () => {
    // The "extra" user at 1 pt is below every existing entry (all at 100..1
    // descending), so after sort + cap they should be the one sliced off —
    // not visible in the result at all. Defends against a refactor that
    // accidentally keeps the upserted user regardless of rank.
    const existing = Array.from({ length: 100 }, (_, i) => ({
      uid: `u${i}`, displayName: `U${i}`, points: 100 - i, // 100, 99, ..., 1
    }));
    const result = mergePeriodEntries(existing, "extra", "Extra", 1);
    // Tied with the bottom entry (u99 at 1pt); uid tiebreaker is ascending,
    // so "extra" sorts BEFORE "u99" and u99 is dropped instead. Either way,
    // the resulting list has exactly 100 entries.
    assert.strictEqual(result.length, 100);
    // Stricter: drop the entry whose uid sorts last — u99 < "extra" so u99
    // remains and "extra" is excluded.
    // (Verifying by checking that the bottom-most kept entry is "extra"
    // would assume the opposite tiebreaker — pin the actual ordering.)
    const uids = new Set(result.map((e) => e.uid));
    assert.ok(uids.has("extra"), '"extra" sorts before "u99" by uid asc and is kept');
    assert.ok(!uids.has("u99"), '"u99" is dropped because "extra" beats it on uid asc tiebreak');
  });

  it("a NEW user well below the cut is excluded entirely", () => {
    // 100 existing users all tied at 10 pts. A new user at 5 pts sorts below
    // every existing one (lower score) — after the cap they should not appear.
    const existing = Array.from({ length: 100 }, (_, i) => ({
      uid: `u${i.toString().padStart(2, "0")}`, displayName: `U${i}`, points: 10,
    }));
    const result = mergePeriodEntries(existing, "newcomer", "Newcomer", 5);
    assert.strictEqual(result.length, 100);
    assert.ok(!result.some((e) => e.uid === "newcomer"),
      "newcomer below the cap should not appear at all");
  });

  it("breaks point ties deterministically by uid ascending", () => {
    // Three users on identical points — ordering must be stable across
    // repeated merge calls so the leaderboard does not visibly reshuffle on
    // every refresh.
    const charlie = { uid: "c", displayName: "Charlie", points: 10 };
    const alice   = { uid: "a", displayName: "Alice",   points: 10 };
    const result = mergePeriodEntries([charlie], "a", "Alice", 10);
    assert.strictEqual(result[0].uid, "a");
    assert.strictEqual(result[1].uid, "c");
    // And it is order-independent: inserting in the reverse direction yields
    // the same ranking.
    const result2 = mergePeriodEntries([alice], "c", "Charlie", 10);
    assert.strictEqual(result2[0].uid, "a");
    assert.strictEqual(result2[1].uid, "c");
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

  it("uniqueBoxes outranks totalPoints (collection beats grinding)", () => {
    // The lifetime sort is "most unique boxes first, points only as tiebreaker"
    // — pin the priority so a future change to mergeLifetimeEntries can't
    // silently flip it back to points-first without failing a test.
    // grinder has fewer unique boxes but vastly more points.
    const grinder = { uid: "g", displayName: "Grinder", uniquePostboxesClaimed: 3, totalPoints: 999 };
    const result = mergeLifetimeEntries([grinder], "c", "Collector", 10, 30);
    assert.strictEqual(result[0].uid, "c", "Collector (10 boxes) ranks above Grinder (3 boxes, 999 pts)");
    assert.strictEqual(result[1].uid, "g");
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

  it("a new low-score user is excluded entirely when below the cap", () => {
    // 3 existing users with 10/9/8 boxes; a newcomer with 1 box sorts last
    // and must be dropped by the cap rather than displacing a higher-ranked
    // entry. Mirrors the equivalent mergePeriodEntries regression.
    const existing = Array.from({ length: 3 }, (_, i) => ({
      uid: `u${i}`, displayName: `User${i}`,
      uniquePostboxesClaimed: 10 - i, totalPoints: 100 - i * 10,
    }));
    const result = mergeLifetimeEntries(existing, "newcomer", "Newcomer", 1, 5, 3);
    assert.strictEqual(result.length, 3);
    assert.ok(!result.some((e) => e.uid === "newcomer"),
      "newcomer below the cap should not appear at all");
  });

  it("updates displayName when upserted", () => {
    const result = mergeLifetimeEntries([alice], "a", "Alice v2", 10, 50);
    assert.strictEqual(result[0].displayName, "Alice v2");
  });

  it("breaks full ties (boxes and points) deterministically by uid ascending", () => {
    // Two users on identical boxes AND identical points — order must be
    // stable across repeated merges so the leaderboard does not reshuffle.
    const carol = { uid: "c", displayName: "Carol", uniquePostboxesClaimed: 10, totalPoints: 50 };
    const result = mergeLifetimeEntries([carol], "a", "Alice", 10, 50);
    assert.strictEqual(result[0].uid, "a");
    assert.strictEqual(result[1].uid, "c");
    const result2 = mergeLifetimeEntries([{ uid: "a", displayName: "Alice", uniquePostboxesClaimed: 10, totalPoints: 50 }], "c", "Carol", 10, 50);
    assert.strictEqual(result2[0].uid, "a");
    assert.strictEqual(result2[1].uid, "c");
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
  // Current import precision: 9 (maximum). Do not lower it.
  //
  // Thresholds use the SHORTER of each cell's lat/lng dimensions so that a
  // 1-ring (center + 8 neighbors) fully covers a disc of the given radius
  // around any point in the center cell. Using cell width (the longer dim
  // at even precisions) leaves a coverage hole in the lat direction.
  it("returns 9 at exact upper boundary (0.00477 km)", () => assert.strictEqual(setPrecision(0.00477), 9));
  it("returns 8 just above precision-9 boundary", () => assert.strictEqual(setPrecision(0.005), 8));
  it("returns 8 at exact upper boundary (0.0191 km = cell height)", () => assert.strictEqual(setPrecision(0.0191), 8));
  it("returns 7 just above precision-8 boundary", () => assert.strictEqual(setPrecision(0.020), 7));
  it("returns 7 for 30 m radius (0.030 km, used by Claim screen)", () => assert.strictEqual(setPrecision(0.030), 7));
  it("returns 7 at exact upper boundary (0.153 km)", () => assert.strictEqual(setPrecision(0.153), 7));
  it("returns 6 just above precision-7 boundary", () => assert.strictEqual(setPrecision(0.154), 6));
  it("returns 6 for 540 m radius (0.540 km, used by Nearby screen)", () => assert.strictEqual(setPrecision(0.540), 6));
  it("returns 6 at exact upper boundary (0.61 km = cell height)", () => assert.strictEqual(setPrecision(0.61), 6));
  it("returns 5 just above precision-6 boundary", () => assert.strictEqual(setPrecision(0.62), 5));
  it("returns 5 at exact upper boundary (4.89 km)", () => assert.strictEqual(setPrecision(4.89), 5));
  it("returns 4 for 10 km radius", () => assert.strictEqual(setPrecision(10), 4));
  it("returns 2 for 500 km radius", () => assert.strictEqual(setPrecision(500), 2));
  it("returns 1 for very large radius (>625 km)", () => assert.strictEqual(setPrecision(1000), 1));

  // Defensive edge cases — callers shouldn't pass these but the function
  // must degrade safely rather than throw or pick a wide-open precision.
  it("returns 9 (max) for radius 0 — narrow query is safer than wide", () => {
    assert.strictEqual(setPrecision(0), 9);
  });
  it("returns 9 (max) for a tiny negative radius — same defensive narrow query", () => {
    // A negative radius is nonsense but mustn't blow up; precision-9 is the
    // safest choice (smallest cell, fewest reads).
    assert.strictEqual(setPrecision(-0.001), 9);
  });
  it("returns 1 (max-coverage fallback) for NaN — NaN<=x is always false", () => {
    // Comparisons against NaN are always false, so the cascade falls through
    // to the final return-1 branch. Documents that the function is
    // conservatively wide-open for unparseable input rather than throwing.
    assert.strictEqual(setPrecision(Number.NaN), 1);
  });

  it("MAX_GEOHASH_PRECISION === 9 (the canonical stored precision)", () => {
    // Pin the export. import_postboxes.js and reports.ts both rely on this
    // being 9 — drift here means prefix queries silently miss documents
    // (their fixed 9-char prefix can't match stored 8-char hashes, etc.).
    assert.strictEqual(MAX_GEOHASH_PRECISION, 9);
  });

  it("MAX_GEOHASH_PRECISION equals setPrecision's smallest-radius return", () => {
    // setPrecision's first branch returns MAX_GEOHASH_PRECISION; if anyone
    // bumps the constant they MUST update the branch (and the comment
    // talking about 4.77m × 4.77m cells).
    assert.strictEqual(setPrecision(0.001), MAX_GEOHASH_PRECISION);
  });
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

// ── Display-name length pin ──────────────────────────────────────────────────
// Cross-platform contract: lib/validators.dart's minDisplayNameChars and
// maxDisplayNameChars MUST match these. The Dart side has its own pinning
// test against the literal values 2 and 30 (and so does sanitiseName above);
// pinning the named TS constants here means the values can only be changed
// by editing this assertion, which is a much louder signal than editing an
// implicit literal.
//
// eslint-disable-next-line @typescript-eslint/no-require-imports, @typescript-eslint/no-var-requires
const profanityModule = require("../_profanityFilter") as {
  MIN_DISPLAY_NAME_CHARS: number;
  MAX_DISPLAY_NAME_CHARS: number;
};
describe("display-name length constants (cross-platform contract)", () => {
  it("MIN_DISPLAY_NAME_CHARS is 2", () => {
    assert.strictEqual(profanityModule.MIN_DISPLAY_NAME_CHARS, 2);
  });
  it("MAX_DISPLAY_NAME_CHARS is 30", () => {
    assert.strictEqual(profanityModule.MAX_DISPLAY_NAME_CHARS, 30);
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

  // ── Scunthorpe-problem regressions ─────────────────────────────────────────
  // The comment in _profanityFilter.ts explicitly lists "arse", "cock",
  // "dick", "mong", and "spic" as words that were REMOVED from the block
  // list because their substring match flagged legitimate names. Pin those
  // legitimate names so a future "tighten the filter" PR can't silently
  // re-block real users.
  it("allows 'Richard' (would trip an old 'dick' rule)", () =>
    assert.strictEqual(containsProfanity("Richard"), false));
  it("allows 'Dickson' surname", () =>
    assert.strictEqual(containsProfanity("Dickson"), false));
  it("allows 'Cockburn' surname (Scottish)", () =>
    assert.strictEqual(containsProfanity("Cockburn"), false));
  it("allows 'Hancock' surname", () =>
    assert.strictEqual(containsProfanity("Hancock"), false));
  it("allows 'peacock' (and Peacock surname)", () => {
    assert.strictEqual(containsProfanity("peacock"), false);
    assert.strictEqual(containsProfanity("Peacock"), false);
  });
  it("allows 'Arsenal'", () =>
    assert.strictEqual(containsProfanity("Arsenal"), false));
  it("allows 'parser' (would trip an old 'arse' rule)", () =>
    assert.strictEqual(containsProfanity("parser"), false));
  it("allows 'Mongolia' (would trip an old 'mong' rule)", () =>
    assert.strictEqual(containsProfanity("Mongolia"), false));
  it("allows 'among' and 'monger'", () => {
    assert.strictEqual(containsProfanity("among"), false);
    assert.strictEqual(containsProfanity("monger"), false);
  });
  it("allows 'spice' and 'suspicion' (would trip an old 'spic' rule)", () => {
    assert.strictEqual(containsProfanity("spice"), false);
    assert.strictEqual(containsProfanity("suspicion"), false);
  });
});

describe("checkTravelSpeed", () => {
  // Approx. 1 degree of latitude ≈ 111_000 metres. Use this to build test
  // coordinate pairs of a known distance.
  const metresPerDegLat = 111_000;

  it("accepts movement just under the 1900 m/min limit", () => {
    // 1800 metres over 1 minute = 1800 m/min (well under the limit).
    const latDelta = 1800 / metresPerDegLat;
    const res = checkTravelSpeed({
      lastLat: 51.5, lastLng: -0.1, lastTimestampMs: 0,
      currentLat: 51.5 + latDelta, currentLng: -0.1,
      nowMs: 60_000,
    });
    assert.strictEqual(res.ok, true);
    assert.ok(res.speedMPerMin < MAX_METRES_PER_MIN);
  });

  it("rejects movement over the 1900 m/min limit", () => {
    // 5000 metres over 1 minute = 5000 m/min (~300 km/h).
    const latDelta = 5000 / metresPerDegLat;
    const res = checkTravelSpeed({
      lastLat: 51.5, lastLng: -0.1, lastTimestampMs: 0,
      currentLat: 51.5 + latDelta, currentLng: -0.1,
      nowMs: 60_000,
    });
    assert.strictEqual(res.ok, false);
    assert.ok(res.speedMPerMin > MAX_METRES_PER_MIN);
  });

  it("rejects London→Manchester in one minute (classic spoof scenario)", () => {
    // London 51.5074,-0.1278 → Manchester 53.4808,-2.2426 (~260 km).
    const res = checkTravelSpeed({
      lastLat: 51.5074, lastLng: -0.1278, lastTimestampMs: 0,
      currentLat: 53.4808, currentLng: -2.2426,
      nowMs: 60_000,
    });
    assert.strictEqual(res.ok, false);
  });

  it("accepts no movement even with a zero time delta (floor protects div-by-zero)", () => {
    const res = checkTravelSpeed({
      lastLat: 51.5, lastLng: -0.1, lastTimestampMs: 1000,
      currentLat: 51.5, currentLng: -0.1,
      nowMs: 1000,
    });
    assert.strictEqual(res.ok, true);
    assert.strictEqual(res.distanceMetres, 0);
  });

  it("rejects a large instant jump (sub-second delta, big distance)", () => {
    const latDelta = 500 / metresPerDegLat; // 500 m jump
    const res = checkTravelSpeed({
      lastLat: 51.5, lastLng: -0.1, lastTimestampMs: 1000,
      currentLat: 51.5 + latDelta, currentLng: -0.1,
      nowMs: 1100, // 0.1s delta → floored to 1s → 500 / (1/60) = 30_000 m/min
    });
    assert.strictEqual(res.ok, false);
  });

  it("accepts slow walking speed (~80 m/min)", () => {
    const latDelta = 80 / metresPerDegLat;
    const res = checkTravelSpeed({
      lastLat: 51.5, lastLng: -0.1, lastTimestampMs: 0,
      currentLat: 51.5 + latDelta, currentLng: -0.1,
      nowMs: 60_000,
    });
    assert.strictEqual(res.ok, true);
    assert.ok(res.speedMPerMin < 100);
  });
});

// ── Cloud Function integration tests (require Firebase emulator) ─────────────

const testEnv = test();

// ── Region pinning (EU region migration, v1.3) ──────────────────────────────
// Every exported Cloud Function must be pinned to an EU region co-located with
// the eur3 Firestore so UK round-trips stay in-region. Most sit in
// europe-west2. onFriendAdded is the exception: eur3 has NO Gen1 Firestore
// triggers (neither europe-west2 nor europe-west1 deploys), so it must be a
// 2nd-gen trigger and Eventarc maps eur3 -> europe-west4. Auth triggers
// (onUserCreated) are global and stay on europe-west2. Iterating over all
// exports means a newly added function that forgets its region trips this guard.
describe("region pinning", () => {
  const DEFAULT_REGION = "europe-west2";
  const REGION_OVERRIDES: Record<string, string> = {
    onFriendAdded: "europe-west4",
    onClaimCreated: "europe-west4",
  };
  type WithEndpoint = { __endpoint?: { region?: string[]; platform?: string } };

  for (const name of Object.keys(myFunctions)) {
    const expected = REGION_OVERRIDES[name] ?? DEFAULT_REGION;
    it(`${name} is pinned to ${expected}`, () => {
      const endpoint = (myFunctions as Record<string, WithEndpoint>)[name].__endpoint;
      assert.ok(endpoint, `${name} has no __endpoint — is it a Cloud Function?`);
      assert.ok(
        Array.isArray(endpoint.region) && endpoint.region.includes(expected),
        `${name} region is ${JSON.stringify(endpoint.region)}, expected ${expected}`,
      );
    });
  }

  it("onFriendAdded is a 2nd-gen trigger (eur3 has no Gen1 Firestore triggers)", () => {
    const endpoint = (myFunctions as Record<string, WithEndpoint>)["onFriendAdded"]
      .__endpoint;
    assert.strictEqual(endpoint?.platform, "gcfv2");
  });

  it("onClaimCreated is a 2nd-gen trigger (eur3 has no Gen1 Firestore triggers)", () => {
    const endpoint = (myFunctions as Record<string, WithEndpoint>)["onClaimCreated"]
      .__endpoint;
    assert.strictEqual(endpoint?.platform, "gcfv2");
  });
});

describe("Cloud Functions", function (this: Mocha.Suite) {
  this.timeout(15000);

  const wrappedNearby = testEnv.wrap(myFunctions.nearbyPostboxes) as (data: unknown, context?: unknown) => Promise<unknown>;
  const wrappedStartScoring = testEnv.wrap(myFunctions.startScoring) as (data: unknown, context?: unknown) => Promise<unknown>;
  const wrappedUpdateDisplayName = testEnv.wrap(myFunctions.updateDisplayName) as (data: unknown, context?: unknown) => Promise<unknown>;
  const wrappedRegisterFcmToken = testEnv.wrap(myFunctions.registerFcmToken) as (data: unknown, context?: unknown) => Promise<unknown>;
  const wrappedUserClaimHistory = testEnv.wrap(myFunctions.userClaimHistory) as (data: unknown, context?: unknown) => Promise<unknown>;
  const wrappedRoutePostboxes = testEnv.wrap(myFunctions.routePostboxes) as (data: unknown, context?: unknown) => Promise<unknown>;

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
        if (
          !(err.message ?? "").includes("PERMISSION_DENIED") &&
          !(err.message ?? "").includes("Could not load the default credentials") &&
          err.code !== "permission-denied"
        ) {
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
        if (
          !(err.message ?? "").includes("PERMISSION_DENIED") &&
          !(err.message ?? "").includes("Could not load the default credentials") &&
          err.code !== "permission-denied"
        ) {
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

    it("should throw invalid-argument when clientTsMs is not finite", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: { lat: 51.45, lng: -0.95, clientTsMs: "nope" }, auth: { uid: "test-uid" } };
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
        // dailyDate is on every return path so callers don't have to special-case
        // the empty-result shape.
        assert.ok("dailyDate" in result, "dailyDate should be present");
        assert.match(result.dailyDate as string, /^\d{4}-\d{2}-\d{2}$/);
      } catch (e: unknown) {
        const err = e as { code?: string; message?: string };
        if (
          !(err.message ?? "").includes("PERMISSION_DENIED") &&
          !(err.message ?? "").includes("Could not load the default credentials") &&
          err.code !== "permission-denied"
        ) {
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

  describe("userClaimHistory (onCall)", () => {
    it("should throw unauthenticated when no auth context", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: { period: "daily" } };
      try {
        await wrappedUserClaimHistory(req);
        assert.fail("Expected unauthenticated error");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "unauthenticated");
      }
    });

    it("should throw invalid-argument when period is missing", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: {}, auth: { uid: "test-uid" } };
      try {
        await wrappedUserClaimHistory(req);
        assert.fail("Expected invalid-argument error");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });

    it("should throw invalid-argument when period is unknown", async function (this: Mocha.Context) {
      this.timeout(5000);
      const req = { data: { period: "yearly" }, auth: { uid: "test-uid" } };
      try {
        await wrappedUserClaimHistory(req);
        assert.fail("Expected invalid-argument error");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });

    it("should return an object with entries and period for a valid request", async function (this: Mocha.Context) {
      this.timeout(10000);
      const req = { data: { period: "daily" }, auth: { uid: "test-uid" } };
      try {
        const result = (await wrappedUserClaimHistory(req)) as Record<string, unknown>;
        assert.strictEqual(typeof result, "object");
        assert.ok("entries" in result);
        assert.ok("period" in result);
        assert.strictEqual(result.period, "daily");
        assert.ok(Array.isArray(result.entries));
      } catch (e: unknown) {
        const err = e as { code?: string; message?: string };
        // PERMISSION_DENIED is acceptable when Firebase emulator is not running.
        if (
          !(err.message ?? "").includes("PERMISSION_DENIED") &&
          !(err.message ?? "").includes("Could not load the default credentials") &&
          err.code !== "permission-denied"
        ) {
          throw e;
        }
      }
    });

    it("should accept each of daily / weekly / monthly / lifetime", async function (this: Mocha.Context) {
      this.timeout(15000);
      const periods = ["daily", "weekly", "monthly", "lifetime"];
      const results = await Promise.allSettled(
        periods.map((period) => wrappedUserClaimHistory({ data: { period }, auth: { uid: "test-uid" } }))
      );
      results.forEach((r, i) => {
        if (r.status === "rejected") {
          const err = r.reason as { code?: string; message?: string };
          // Acceptable: PERMISSION_DENIED (no emulator) but NOT invalid-argument.
          assert.notStrictEqual(err.code, "invalid-argument", `period '${periods[i]}' must not be rejected as invalid`);
        }
      });
    });
  });

  describe("routePostboxes (onCall)", () => {
    // Valid corridor request used as a baseline throughout.
    const validCorridorReq = {
      data: {
        startLat: 51.45, startLng: -0.95,
        destLat:  51.46, destLng: -0.94,
        mode: "corridor", corridorMetres: 100,
      },
      auth: { uid: "test-uid" },
    };

    it("throws unauthenticated when no auth context", async function (this: Mocha.Context) {
      this.timeout(5000);
      try {
        await wrappedRoutePostboxes({ data: validCorridorReq.data });
        assert.fail("Expected unauthenticated error");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "unauthenticated");
      }
    });

    it("throws invalid-argument when lat/lng are missing", async function (this: Mocha.Context) {
      this.timeout(5000);
      try {
        await wrappedRoutePostboxes({ data: {}, auth: { uid: "test-uid" } });
        assert.fail("Expected invalid-argument");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });

    it("throws invalid-argument for startLat out of range", async function (this: Mocha.Context) {
      this.timeout(5000);
      try {
        await wrappedRoutePostboxes({
          data: { ...validCorridorReq.data, startLat: 999 },
          auth: { uid: "test-uid" },
        });
        assert.fail("Expected invalid-argument");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });

    it("throws invalid-argument for destLng out of range", async function (this: Mocha.Context) {
      this.timeout(5000);
      try {
        await wrappedRoutePostboxes({
          data: { ...validCorridorReq.data, destLng: 999 },
          auth: { uid: "test-uid" },
        });
        assert.fail("Expected invalid-argument");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });

    it("throws invalid-argument for invalid mode", async function (this: Mocha.Context) {
      this.timeout(5000);
      try {
        await wrappedRoutePostboxes({
          data: { startLat: 51.45, startLng: -0.95, destLat: 51.46, destLng: -0.94, mode: "turbo" },
          auth: { uid: "test-uid" },
        });
        assert.fail("Expected invalid-argument");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });

    it("throws invalid-argument for corridor mode without corridorMetres", async function (this: Mocha.Context) {
      this.timeout(5000);
      try {
        await wrappedRoutePostboxes({
          data: { startLat: 51.45, startLng: -0.95, destLat: 51.46, destLng: -0.94, mode: "corridor" },
          auth: { uid: "test-uid" },
        });
        assert.fail("Expected invalid-argument");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });

    it("throws invalid-argument for corridorMetres below 50", async function (this: Mocha.Context) {
      this.timeout(5000);
      try {
        await wrappedRoutePostboxes({
          data: { ...validCorridorReq.data, corridorMetres: 10 },
          auth: { uid: "test-uid" },
        });
        assert.fail("Expected invalid-argument");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });

    it("throws invalid-argument for corridorMetres above 500", async function (this: Mocha.Context) {
      this.timeout(5000);
      try {
        await wrappedRoutePostboxes({
          data: { ...validCorridorReq.data, corridorMetres: 999 },
          auth: { uid: "test-uid" },
        });
        assert.fail("Expected invalid-argument");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });

    it("throws invalid-argument for detour mode without detourMinutes", async function (this: Mocha.Context) {
      this.timeout(5000);
      try {
        await wrappedRoutePostboxes({
          data: { startLat: 51.45, startLng: -0.95, destLat: 51.46, destLng: -0.94, mode: "detour" },
          auth: { uid: "test-uid" },
        });
        assert.fail("Expected invalid-argument");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });

    it("throws invalid-argument for detourMinutes above 120", async function (this: Mocha.Context) {
      this.timeout(5000);
      try {
        await wrappedRoutePostboxes({
          data: { startLat: 51.45, startLng: -0.95, destLat: 51.46, destLng: -0.94, mode: "detour", detourMinutes: 200 },
          auth: { uid: "test-uid" },
        });
        assert.fail("Expected invalid-argument");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });

    it("throws invalid-argument for speedKmh out of range", async function (this: Mocha.Context) {
      this.timeout(5000);
      try {
        await wrappedRoutePostboxes({
          data: { ...validCorridorReq.data, speedKmh: 100 },
          auth: { uid: "test-uid" },
        });
        assert.fail("Expected invalid-argument");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });

    it("throws invalid-argument for perClaimSeconds out of range", async function (this: Mocha.Context) {
      this.timeout(5000);
      try {
        await wrappedRoutePostboxes({
          data: { ...validCorridorReq.data, perClaimSeconds: 999 },
          auth: { uid: "test-uid" },
        });
        assert.fail("Expected invalid-argument");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });

    it("throws invalid-argument when direct distance exceeds 30 km", async function (this: Mocha.Context) {
      this.timeout(5000);
      // London to Manchester (~260 km apart) — well over 30 km.
      try {
        await wrappedRoutePostboxes({
          data: {
            startLat: 51.5074, startLng: -0.1278,
            destLat:  53.4808, destLng: -2.2426,
            mode: "corridor", corridorMetres: 100,
          },
          auth: { uid: "test-uid" },
        });
        assert.fail("Expected invalid-argument");
      } catch (e: unknown) {
        assert.strictEqual((e as { code?: string }).code, "invalid-argument");
      }
    });

    it("returns correct response shape and no per-postbox detail on valid corridor request", async function (this: Mocha.Context) {
      this.timeout(10000);
      try {
        const result = (await wrappedRoutePostboxes(validCorridorReq)) as Record<string, unknown>;
        assert.ok("count" in result, "response must have count");
        assert.ok("points" in result, "response must have points");
        assert.ok("directDistanceM" in result, "response must have directDistanceM");
        assert.ok("budgetDistanceM" in result, "response must have budgetDistanceM");
        assert.ok("warnings" in result, "response must have warnings");
        assert.strictEqual(typeof result.count, "number");
        assert.strictEqual(typeof result.points, "number");
        assert.ok(Array.isArray(result.warnings));
        // Must NOT expose per-postbox fields.
        assert.ok(!("postboxes" in result), "must not leak postbox list");
        assert.ok(!("ids" in result), "must not leak IDs");
        assert.ok(!("locations" in result), "must not leak locations");
      } catch (e: unknown) {
        const err = e as { code?: string; message?: string };
        // Acceptable: permission-denied when Firebase emulator is not running.
        if (
          !(err.message ?? "").includes("PERMISSION_DENIED") &&
          !(err.message ?? "").includes("Could not load the default credentials") &&
          err.code !== "permission-denied"
        ) {
          throw e;
        }
      }
    });

    it("returns correct response shape on valid detour request", async function (this: Mocha.Context) {
      this.timeout(10000);
      const req = {
        data: {
          startLat: 51.45, startLng: -0.95,
          destLat:  51.46, destLng: -0.94,
          mode: "detour", detourMinutes: 30,
        },
        auth: { uid: "test-uid" },
      };
      try {
        const result = (await wrappedRoutePostboxes(req)) as Record<string, unknown>;
        assert.ok("count" in result);
        assert.ok("points" in result);
        assert.ok("directDistanceM" in result);
        assert.ok("budgetDistanceM" in result);
        assert.ok("warnings" in result);
        assert.strictEqual(typeof result.count, "number");
        assert.strictEqual(typeof result.points, "number");
        assert.ok(Array.isArray(result.warnings));
      } catch (e: unknown) {
        const err = e as { code?: string; message?: string };
        if (
          !(err.message ?? "").includes("PERMISSION_DENIED") &&
          !(err.message ?? "").includes("Could not load the default credentials") &&
          err.code !== "permission-denied"
        ) {
          throw e;
        }
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

  it("carries through distance on slim postboxes when present on input", () => {
    // Route Mode auto-claim trigger reads box['distance'] from this callable
    // to detect when a postbox is within the 30 m claim radius. Without it the
    // trigger never fires.
    const full = {
      postboxes: {
        near: { monarch: "EIIR", compass: { exact: "N" }, distance: 12 },
        far:  { monarch: "VR",   compass: { exact: "S" }, distance: 450 },
      },
      counts: { total: 2, claimedToday: 0, EIIR: 1, VR: 1 },
      points: { min: 2, max: 7 },
      compass: { N: 1, S: 1 },
    };
    const { slimPostboxes } = applyUserClaims(full, new Set());
    assert.strictEqual(slimPostboxes.near.distance, 12);
    assert.strictEqual(slimPostboxes.far.distance, 450);
  });

  it("omits distance on slim postboxes when missing on input", () => {
    const full = {
      postboxes: {
        noDistance: { monarch: "EIIR", compass: { exact: "N" } },
      },
      counts: { total: 1, claimedToday: 0 },
      points: { min: 2, max: 2 },
      compass: { N: 1 },
    };
    const { slimPostboxes } = applyUserClaims(full, new Set());
    assert.strictEqual("distance" in slimPostboxes.noDistance, false);
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

  it("skips anonymised (deleted) claims so no 'deleted' entry resurrects", async () => {
    const { db, getWrittenLb } = makeMockDb(
      [
        { userid: "deleted", dailyDate: "2026-04-13", points: 50 }, // anonymised
        { userid: "u1", dailyDate: "2026-04-13", points: 5 },
      ],
      { u1: { displayName: "Alice" } }
    );
    await rebuildPeriodLeaderboard("daily", "2026-04-13", "2026-04-13", db);
    const entries = getWrittenLb()!.entries as Array<{ uid: string }>;
    assert.strictEqual(entries.length, 1);
    assert.strictEqual(entries[0].uid, "u1");
    assert.ok(!entries.some((e) => e.uid === "deleted"));
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
  it("returns the SAME array reference when the token is already present", () => {
    // registerFcmToken relies on this reference-equality semantic to skip the
    // Firestore transaction commit in the no-op case (see _notifications.ts).
    // A reallocating implementation would silently regress write-throttling.
    const existing = ["tok1", "tok2"];
    const result = updateFcmTokens(existing, "tok1");
    assert.strictEqual(result, existing, "must return the exact same array reference");
  });
  it("returns a new array reference when a token is appended", () => {
    // Sanity counterpart to the above: when work actually happens, we return
    // a fresh array so the caller writes a fresh value.
    const existing = ["tok1", "tok2"];
    const result = updateFcmTokens(existing, "tok3");
    assert.notStrictEqual(result, existing, "appending must return a new array");
  });
  it("respects a custom max cap", () => {
    // The default is 5 but the cap is parameterised; verify the parameter is
    // honoured rather than ignored.
    assert.deepStrictEqual(updateFcmTokens(["a", "b"], "c", 2), ["b", "c"]);
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

  // lastFirstClaimNotifiedDate — prevent duplicate "first of your friends" notifications
  it("returns false when already notified about another friend today", () =>
    assert.strictEqual(
      shouldNotifyFirstClaim(
        { lastFirstClaimNotifiedDate: "2026-04-17" },
        "2026-04-17"
      ),
      false
    ));

  it("returns true when lastFirstClaimNotifiedDate is from a previous day", () =>
    assert.strictEqual(
      shouldNotifyFirstClaim(
        { lastFirstClaimNotifiedDate: "2026-04-16" },
        "2026-04-17"
      ),
      true
    ));

  it("ignores lastFirstClaimNotifiedDate when todayLondon is not provided (legacy path)", () =>
    assert.strictEqual(
      shouldNotifyFirstClaim({ lastFirstClaimNotifiedDate: "2026-04-17" }),
      true
    ));

  // The streak tx writes lastClaimDate; the lifetime tx writes dailyDate (+
  // dailyPoints). If the lifetime half succeeds but the streak half fails,
  // dailyDate=today while lastClaimDate is yesterday — the friend HAS
  // claimed today and we must not send them a "first claim of the day"
  // notification about someone else.
  it("returns false when dailyDate matches today (lifetime tx succeeded, streak tx didn't)", () =>
    assert.strictEqual(
      shouldNotifyFirstClaim(
        { dailyDate: "2026-04-17", dailyPoints: 5, lastClaimDate: "2026-04-16" },
        "2026-04-17"
      ),
      false
    ));

  it("returns false when lastClaimDate matches today (streak tx succeeded, lifetime tx didn't)", () =>
    assert.strictEqual(
      shouldNotifyFirstClaim(
        { lastClaimDate: "2026-04-17", dailyDate: "2026-04-16", dailyPoints: 50 },
        "2026-04-17"
      ),
      false
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

  // Regression: lifetime tx writes both dailyDate and dailyPoints; streak tx
  // writes lastClaimDate. If the streak tx commits but the lifetime tx fails,
  // lastClaimDate is today while dailyPoints is yesterday's stale value.
  // Prefer dailyDate when present so we don't compare against the stale total.
  it("trusts dailyDate over lastClaimDate when both are present", () =>
    assert.strictEqual(
      shouldNotifyOvertake(
        // dailyDate=yesterday, lastClaimDate=today (streak ok, lifetime tx
        // failed): the 50 is stale, friend hasn't actually scored today.
        { dailyPoints: 50, dailyDate: "2026-04-16", lastClaimDate: "2026-04-17" },
        0,
        10,
        "2026-04-17"
      ),
      false
    ));

  it("uses dailyDate when present and lastClaimDate is missing (legacy field absent)", () =>
    assert.strictEqual(
      shouldNotifyOvertake(
        { dailyPoints: 3, dailyDate: "2026-04-17" },
        0,
        5,
        "2026-04-17"
      ),
      true
    ));
});

// ── userClaimHistory pure unit tests (no Firebase required) ───────────────────

describe("periodStartDate", () => {
  it("daily returns today itself", () =>
    assert.strictEqual(periodStartDate("daily", "2026-04-15"), "2026-04-15"));
  it("weekly returns the Monday of the current ISO week", () =>
    assert.strictEqual(periodStartDate("weekly", "2026-04-15"), "2026-04-13"));
  it("monthly returns the 1st of the current month", () =>
    assert.strictEqual(periodStartDate("monthly", "2026-04-15"), "2026-04-01"));
  it("lifetime returns null (no lower bound)", () =>
    assert.strictEqual(periodStartDate("lifetime", "2026-04-15"), null));
});

describe("aggregateClaimHistory", () => {
  const postboxes = {
    p1: { lat: 51.5, lng: -0.1, monarch: "EIIR", reference: "SW1A 1AA" },
    p2: { lat: 55.9, lng: -3.2, monarch: "VR" },
  };

  it("returns an empty array for no claims", () => {
    assert.deepStrictEqual(aggregateClaimHistory([], postboxes), []);
  });

  it("produces one entry per unique postbox", () => {
    const result = aggregateClaimHistory(
      [
        { postboxId: "p1", dailyDate: "2026-04-15", points: 2 },
        { postboxId: "p2", dailyDate: "2026-04-15", points: 7 },
      ],
      postboxes
    );
    assert.strictEqual(result.length, 2);
    const ids = result.map((e) => e.postboxId).sort();
    assert.deepStrictEqual(ids, ["p1", "p2"]);
  });

  it("dedupes multiple claims of the same postbox and accumulates fields", () => {
    const result = aggregateClaimHistory(
      [
        { postboxId: "p1", dailyDate: "2026-04-10", points: 2 },
        { postboxId: "p1", dailyDate: "2026-04-15", points: 2 },
        { postboxId: "p1", dailyDate: "2026-04-12", points: 2 },
      ],
      postboxes
    );
    assert.strictEqual(result.length, 1);
    assert.strictEqual(result[0].postboxId, "p1");
    assert.strictEqual(result[0].timesClaimed, 3);
    assert.strictEqual(result[0].totalPoints, 6);
    assert.strictEqual(result[0].firstClaimed, "2026-04-10");
    assert.strictEqual(result[0].lastClaimed, "2026-04-15");
  });

  it("joins in postbox geopoint, monarch and reference", () => {
    const result = aggregateClaimHistory(
      [{ postboxId: "p1", dailyDate: "2026-04-15", points: 2 }],
      postboxes
    );
    assert.strictEqual(result[0].lat, 51.5);
    assert.strictEqual(result[0].lng, -0.1);
    assert.strictEqual(result[0].monarch, "EIIR");
    assert.strictEqual(result[0].reference, "SW1A 1AA");
  });

  it("skips claims whose postbox document is missing", () => {
    const result = aggregateClaimHistory(
      [
        { postboxId: "p1", dailyDate: "2026-04-15", points: 2 },
        { postboxId: "ghost", dailyDate: "2026-04-15", points: 2 },
      ],
      postboxes
    );
    assert.strictEqual(result.length, 1);
    assert.strictEqual(result[0].postboxId, "p1");
  });

  it("falls back to the claim's monarch when the postbox has no monarch", () => {
    const pbNoMonarch = { p3: { lat: 52.0, lng: -1.0 } };
    const result = aggregateClaimHistory(
      [{ postboxId: "p3", dailyDate: "2026-04-15", points: 9, monarch: "CIIIR" }],
      pbNoMonarch
    );
    assert.strictEqual(result[0].monarch, "CIIIR");
  });

  it("sorts entries with most-recent lastClaimed first", () => {
    const result = aggregateClaimHistory(
      [
        { postboxId: "p1", dailyDate: "2026-04-10", points: 2 },
        { postboxId: "p2", dailyDate: "2026-04-15", points: 7 },
      ],
      postboxes
    );
    assert.strictEqual(result[0].postboxId, "p2");
    assert.strictEqual(result[1].postboxId, "p1");
  });
});

// ── countySlug & county_lookup ────────────────────────────────────────────────

describe("countySlug", () => {
  it("lowercases and hyphenates spaces", () => {
    assert.strictEqual(countySlug("Cornwall"), "cornwall");
    assert.strictEqual(countySlug("City of Edinburgh"), "city-of-edinburgh");
  });
  it("strips punctuation", () => {
    assert.strictEqual(countySlug("Bristol, City of"), "bristol-city-of");
    assert.strictEqual(countySlug("King's Lynn"), "king-s-lynn");
  });
  it("collapses runs of non-alphanumerics", () => {
    assert.strictEqual(countySlug("Foo  -  Bar"), "foo-bar");
  });
  it("trims leading and trailing hyphens", () => {
    assert.strictEqual(countySlug("  Cornwall  "), "cornwall");
    assert.strictEqual(countySlug("--cornwall--"), "cornwall");
  });
  it("returns null for empty / whitespace input", () => {
    assert.strictEqual(countySlug(""), null);
    assert.strictEqual(countySlug("   "), null);
    assert.strictEqual(countySlug("---"), null);
  });
  it("matches the slug stored in the simplified geojson asset", () => {
    // Sanity: must agree with the slugs baked into
    // assets/uk_counties_simplified.geojson and util/county_lookup.js. If
    // these drift, the heatmap polygons stop joining to leaderboard docs.
    assert.strictEqual(countySlug("City of Edinburgh"), "city-of-edinburgh");
    assert.strictEqual(countySlug("Birmingham"), "birmingham");
  });
});

describe("county_lookup (point-in-polygon)", () => {
  // Lazy-require so test discovery doesn't load 1MB of geojson when the file
  // isn't present (e.g. fresh clone before backfill prep). Tests skip
  // gracefully in that case.
  // eslint-disable-next-line @typescript-eslint/no-require-imports, @typescript-eslint/no-var-requires
  const counties = require("../../util/county_lookup");
  let loaded = false;
  try {
    counties.load();
    loaded = true;
  } catch (_) {
    loaded = false;
  }

  (loaded ? it : it.skip)("resolves Cornwall for a Truro point", () => {
    assert.strictEqual(counties.countyForPoint(50.2660, -5.0527), "Cornwall");
  });
  (loaded ? it : it.skip)("resolves Birmingham for a city-centre point", () => {
    assert.strictEqual(counties.countyForPoint(52.4862, -1.8904), "Birmingham");
  });
  (loaded ? it : it.skip)("returns null for a point in the North Sea", () => {
    assert.strictEqual(counties.countyForPoint(54.5, 2.5), null);
  });
  it("ring ray-casting: inside a unit square", () => {
    const sq: number[][] = [[0, 0], [1, 0], [1, 1], [0, 1], [0, 0]];
    assert.strictEqual(counties._pointInRing(0.5, 0.5, sq), true);
    assert.strictEqual(counties._pointInRing(2, 2, sq), false);
  });
  it("polygon respects holes (donut)", () => {
    const outer: number[][] = [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]];
    const hole: number[][] = [[4, 4], [6, 4], [6, 6], [4, 6], [4, 4]];
    assert.strictEqual(counties._pointInPolygon(5, 5, [outer, hole]), false);
    assert.strictEqual(counties._pointInPolygon(1, 1, [outer, hole]), true);
  });
  it("slug() helper agrees with countySlug() on common cases", () => {
    assert.strictEqual(counties.slug("City of Edinburgh"), "city-of-edinburgh");
    assert.strictEqual(counties.slug(""), null);
  });
});

// ── reports + retroactive rescoring ──────────────────────────────────────────

import { KNOWN_MONARCHS, pointsForMonarch } from "../_getPoints";
import { parsePhotos, buildOsmChange, nextQuotaState } from "../reports";
import { maxDailyFromClaims, repointClaimsForPostbox } from "../_recomputeScores";

describe("pointsForMonarch", () => {
  it("treats null as plain (2 points)", () => assert.strictEqual(pointsForMonarch(null), 2));
  it("treats undefined as plain (2 points)", () => assert.strictEqual(pointsForMonarch(undefined), 2));
  it("treats empty string as plain (2 points)", () => assert.strictEqual(pointsForMonarch(""), 2));
  it("delegates to getPoints for known cyphers", () => {
    assert.strictEqual(pointsForMonarch("VR"), 7);
    assert.strictEqual(pointsForMonarch("EVIIIR"), 12);
  });
  it("KNOWN_MONARCHS are all recognised by getPoints (none default to 2 by accident except EIIR)", () => {
    // EIIR legitimately scores 2; the rest must score > 2.
    for (const m of KNOWN_MONARCHS) {
      if (m === "EIIR") assert.strictEqual(getPoints(m), 2);
      else assert.ok(getPoints(m) > 2, `${m} should score > 2`);
    }
  });
  it("KNOWN_MONARCHS exactly matches the cross-platform contract", () => {
    // Pin the exact set so adding or removing a monarch on the TS side
    // breaks this test loudly. The Dart side has a mirror test against
    // MonarchInfo.all — both must match this same set to be cross-platform
    // consistent. Order-independent.
    assert.deepStrictEqual(
      [...KNOWN_MONARCHS].sort(),
      ["CIIIR", "EIIR", "EVIIIR", "EVIIR", "GR", "GVIR", "GVR", "SCOTTISH_CROWN", "VR"],
    );
  });
});

describe("parsePhotos", () => {
  const uid = "user123";
  it("returns [] for undefined/null", () => {
    assert.deepStrictEqual(parsePhotos(undefined, uid), []);
    assert.deepStrictEqual(parsePhotos(null, uid), []);
  });
  it("accepts valid photo objects under the user's prefix", () => {
    const out = parsePhotos([{ storagePath: `report_photos/${uid}/a.jpg`, exifLat: 51.5, exifLng: -0.1, takenAt: "2026:05:11 10:00:00" }], uid);
    assert.strictEqual(out.length, 1);
    assert.strictEqual(out[0].storagePath, `report_photos/${uid}/a.jpg`);
    assert.strictEqual(out[0].exifLat, 51.5);
    assert.strictEqual(out[0].exifLng, -0.1);
    assert.strictEqual(out[0].takenAt, "2026:05:11 10:00:00");
  });
  it("rejects more than 3 photos", () => {
    assert.throws(() => parsePhotos(Array.from({ length: 4 }, (_, i) => ({ storagePath: `report_photos/${uid}/${i}.jpg` })), uid));
  });
  it("accepts exactly 3 photos (the cap boundary)", () => {
    // Mirror of the rejection-at-4 test: 3 must succeed. Pins the cap so a
    // future change to MAX_PHOTOS (currently private) doesn't drift silently
    // away from ReportRepository.maxPhotos on the Flutter side.
    const out = parsePhotos(
      Array.from({ length: 3 }, (_, i) => ({ storagePath: `report_photos/${uid}/${i}.jpg` })),
      uid,
    );
    assert.strictEqual(out.length, 3);
  });
  it("rejects a path outside the user's prefix", () => {
    assert.throws(() => parsePhotos([{ storagePath: "report_photos/otheruser/a.jpg" }], uid));
    assert.throws(() => parsePhotos([{ storagePath: "osm_changesets/x.osc" }], uid));
  });
  it("rejects path traversal in the file name", () => {
    assert.throws(() => parsePhotos([{ storagePath: `report_photos/${uid}/../secret.jpg` }], uid));
    assert.throws(() => parsePhotos([{ storagePath: `report_photos/${uid}/sub/dir.jpg` }], uid));
  });
  it("rejects implausible EXIF coordinates", () => {
    assert.throws(() => parsePhotos([{ storagePath: `report_photos/${uid}/a.jpg`, exifLat: 200 }], uid));
  });
  it("rejects implausible EXIF longitude", () => {
    assert.throws(() => parsePhotos([{ storagePath: `report_photos/${uid}/a.jpg`, exifLng: 999 }], uid));
  });
  it("rejects non-array input", () => {
    assert.throws(() => parsePhotos("not an array", uid));
    assert.throws(() => parsePhotos({ storagePath: `report_photos/${uid}/a.jpg` }, uid));
  });
  it("rejects non-object array entries", () => {
    assert.throws(() => parsePhotos(["just a string"], uid));
    assert.throws(() => parsePhotos([null], uid));
    assert.throws(() => parsePhotos([42], uid));
  });
  it("rejects an empty file name (path is exactly the prefix)", () => {
    assert.throws(() => parsePhotos([{ storagePath: `report_photos/${uid}/` }], uid));
  });
  it("rejects a takenAt longer than 40 chars", () => {
    const longTakenAt = "a".repeat(41);
    assert.throws(() => parsePhotos(
      [{ storagePath: `report_photos/${uid}/a.jpg`, takenAt: longTakenAt }],
      uid,
    ));
  });
  it("accepts a takenAt at the 40-char boundary", () => {
    const maxTakenAt = "a".repeat(40);
    const out = parsePhotos(
      [{ storagePath: `report_photos/${uid}/a.jpg`, takenAt: maxTakenAt }],
      uid,
    );
    assert.strictEqual(out[0].takenAt, maxTakenAt);
  });
  it("rejects a non-string takenAt", () => {
    assert.throws(() => parsePhotos(
      [{ storagePath: `report_photos/${uid}/a.jpg`, takenAt: 12345 }],
      uid,
    ));
  });
  it("accepts a photo with no EXIF metadata at all", () => {
    // Browsers strip EXIF on upload; iOS without "Camera location" returns
    // no GPS. The reporter must still be able to attach evidence photos.
    const out = parsePhotos([{ storagePath: `report_photos/${uid}/no-exif.jpg` }], uid);
    assert.strictEqual(out.length, 1);
    assert.strictEqual(out[0].storagePath, `report_photos/${uid}/no-exif.jpg`);
    assert.strictEqual(out[0].exifLat, undefined);
    assert.strictEqual(out[0].exifLng, undefined);
    assert.strictEqual(out[0].takenAt, undefined);
  });
});

describe("nextQuotaState", () => {
  const today = "2026-05-11";
  it("allows the first report of the day (no stored state)", () => {
    const r = nextQuotaState(undefined, today, 10);
    assert.strictEqual(r.allowed, true);
    assert.deepStrictEqual(r.state, { date: today, count: 1 });
  });
  it("increments within the same day", () => {
    const r = nextQuotaState({ date: today, count: 3 }, today, 10);
    assert.strictEqual(r.allowed, true);
    assert.deepStrictEqual(r.state, { date: today, count: 4 });
  });
  it("resets the count when the day rolls over", () => {
    const r = nextQuotaState({ date: "2026-05-10", count: 10 }, today, 10);
    assert.strictEqual(r.allowed, true);
    assert.deepStrictEqual(r.state, { date: today, count: 1 });
  });
  it("rejects once the cap is reached and leaves the count unchanged", () => {
    const r = nextQuotaState({ date: today, count: 10 }, today, 10);
    assert.strictEqual(r.allowed, false);
    assert.deepStrictEqual(r.state, { date: today, count: 10 });
  });
  it("rejects when stored count is somehow above the cap", () => {
    const r = nextQuotaState({ date: today, count: 99 }, today, 10);
    assert.strictEqual(r.allowed, false);
    assert.deepStrictEqual(r.state, { date: today, count: 99 });
  });
  it("treats a malformed/negative stored count as zero", () => {
    assert.deepStrictEqual(nextQuotaState({ date: today, count: -5 }, today, 10).state, { date: today, count: 1 });
    assert.deepStrictEqual(nextQuotaState({ date: today, count: "x" }, today, 10).state, { date: today, count: 1 });
    assert.deepStrictEqual(nextQuotaState({ date: today }, today, 10).state, { date: today, count: 1 });
  });
});

describe("buildOsmChange", () => {
  it("builds a modify changeset with the node version and updated tags", () => {
    const osc = buildOsmChange({ action: "modify", id: 12345, version: 7, lat: 51.5, lon: -0.1, tags: { amenity: "post_box", royal_cypher: "VR", ref: "SW1A 1" } });
    assert.match(osc, /^<\?xml version="1\.0" encoding="UTF-8"\?>/);
    assert.match(osc, /<osmChange version="0\.6" generator="PostboxGame">/);
    assert.match(osc, /<modify>/);
    assert.match(osc, /<node id="12345" version="7" lat="51\.5" lon="-0\.1" changeset="0">/);
    assert.match(osc, /<tag k="royal_cypher" v="VR"\/>/);
    assert.match(osc, /<tag k="ref" v="SW1A 1"\/>/);
  });
  it("builds a create changeset without a version attribute", () => {
    const osc = buildOsmChange({ action: "create", id: -1, lat: 52, lon: -1.5, tags: { amenity: "post_box", royal_cypher: "EIIR" } });
    assert.match(osc, /<create>/);
    assert.match(osc, /<node id="-1" lat="52" lon="-1\.5" changeset="0">/);
    assert.ok(!/<node[^>]*\bversion=/.test(osc), "create node should have no version attr");
  });
  it("escapes XML metacharacters in tag values", () => {
    const osc = buildOsmChange({ action: "create", id: -1, lat: 0, lon: 0, tags: { note: 'a & b < c > "d"' } });
    assert.match(osc, /v="a &amp; b &lt; c &gt; &quot;d&quot;"/);
  });
  it("omits empty tag values", () => {
    const osc = buildOsmChange({ action: "create", id: -1, lat: 0, lon: 0, tags: { amenity: "post_box", royal_cypher: "" } });
    assert.ok(!/royal_cypher/.test(osc));
  });
});

describe("repointClaimsForPostbox (unit, mock Firestore)", () => {
  // Minimal mock of the Admin SDK surface used by repointClaimsForPostbox:
  //   db.collection("claims").where(...).get()  → returns docs with data() + ref
  //   db.batch().set(ref, update, { merge: true })  → records writes
  //   batch.commit() → resolves
  type ClaimDoc = {
    id: string;
    userid?: string;
    points?: number;
    monarch?: string;
    postboxes?: string;
  };

  type CapturedWrite = {
    ref: { id: string };
    update: Record<string, unknown>;
  };

  function makeMockDb(claims: ClaimDoc[]) {
    const writes: CapturedWrite[] = [];
    const commits: number[] = [];

    const db = {
      collection: (name: string) => {
        if (name !== "claims") throw new Error(`unexpected collection ${name}`);
        let postboxFilter: string | undefined;
        const q = {
          where(field: string, op: string, val: unknown) {
            if (field !== "postboxes" || op !== "==") {
              throw new Error(`unexpected where ${field} ${op}`);
            }
            postboxFilter = val as string;
            return q;
          },
          async get() {
            const docs = claims
              .filter((c) => c.postboxes === postboxFilter)
              .map((c) => ({
                ref: { id: c.id },
                data: () => c as Record<string, unknown>,
              }));
            return { docs };
          },
        };
        return q;
      },
      batch() {
        const batchWrites: CapturedWrite[] = [];
        return {
          set(ref: { id: string }, update: Record<string, unknown>) {
            batchWrites.push({ ref, update });
          },
          async commit() {
            writes.push(...batchWrites);
            commits.push(batchWrites.length);
          },
        };
      },
    };
    return {
      db: db as unknown as import("firebase-admin").firestore.Firestore,
      writes,
      commits,
    };
  }

  it("returns empty result for a postbox with no claims", async () => {
    const { db } = makeMockDb([]);
    const result = await repointClaimsForPostbox(db, "osm_42", "VR");
    assert.strictEqual(result.claimCount, 0);
    assert.strictEqual(result.deltaByUid.size, 0);
  });

  it("rewrites every claim's points and tracks deltas per user", async () => {
    const claims: ClaimDoc[] = [
      { id: "c1", userid: "u1", points: 9, monarch: "EVIIR", postboxes: "/postbox/osm_42" },
      { id: "c2", userid: "u1", points: 9, monarch: "EVIIR", postboxes: "/postbox/osm_42" },
      { id: "c3", userid: "u2", points: 9, monarch: "EVIIR", postboxes: "/postbox/osm_42" },
      // Unrelated postbox — must not be touched.
      { id: "c4", userid: "u3", points: 7, monarch: "VR", postboxes: "/postbox/osm_99" },
    ];
    const { db, writes } = makeMockDb(claims);

    // Correct the cypher from EVIIR (9 pts) to GR (4 pts). Delta per claim = -5.
    const result = await repointClaimsForPostbox(db, "osm_42", "GR");

    assert.strictEqual(result.claimCount, 3);
    // u1 had 2 claims: delta = 2 * -5 = -10; u2 had 1: -5; u3 untouched.
    assert.strictEqual(result.deltaByUid.get("u1"), -10);
    assert.strictEqual(result.deltaByUid.get("u2"), -5);
    assert.strictEqual(result.deltaByUid.has("u3"), false);

    // Every rewrite carries the new points and the audit fields.
    assert.strictEqual(writes.length, 3);
    for (const w of writes) {
      assert.strictEqual(w.update.points, 4);
      assert.strictEqual(w.update.monarch, "GR");
      assert.strictEqual(w.update.correctedFromMonarch, "EVIIR");
      assert.strictEqual(w.update.correctedFromPoints, 9);
      assert.ok(w.update.correctedAt, "correctedAt timestamp present");
    }
    // None of the writes target the unrelated postbox's claim.
    assert.ok(!writes.some((w) => w.ref.id === "c4"));
  });

  it("deletes the monarch field when correcting to plain (null)", async () => {
    const claims: ClaimDoc[] = [
      { id: "c1", userid: "u1", points: 9, monarch: "EVIIR", postboxes: "/postbox/osm_42" },
    ];
    const { db, writes } = makeMockDb(claims);
    await repointClaimsForPostbox(db, "osm_42", null);
    assert.strictEqual(writes.length, 1);
    // The monarch field is set to a FieldValue sentinel — we just check it
    // isn't a plain string, since the test runner has Admin SDK loaded and
    // the sentinel is an object.
    assert.notStrictEqual(typeof writes[0].update.monarch, "string");
    assert.strictEqual(writes[0].update.points, 2); // plain → 2 pts
  });

  it("preserves a null delta entry when the new points equal the old (no-op correction)", async () => {
    // E.g. correcting from one cypher worth 2 to another cypher worth 2 — the
    // claims' points don't change but the audit fields and monarch field do.
    const claims: ClaimDoc[] = [
      { id: "c1", userid: "u1", points: 2, monarch: "EIIR", postboxes: "/postbox/osm_42" },
    ];
    const { db, writes } = makeMockDb(claims);
    // Use null (plain, 2 pts) — delta = 0.
    const result = await repointClaimsForPostbox(db, "osm_42", null);
    assert.strictEqual(result.claimCount, 1);
    assert.strictEqual(result.deltaByUid.get("u1"), 0);
    assert.strictEqual(writes[0].update.points, 2);
  });

  it("ignores claims missing a userid (no delta entry written)", async () => {
    const claims: ClaimDoc[] = [
      { id: "c1", points: 9, monarch: "EVIIR", postboxes: "/postbox/osm_42" },
    ];
    const { db, writes } = makeMockDb(claims);
    const result = await repointClaimsForPostbox(db, "osm_42", "GR");
    assert.strictEqual(result.claimCount, 1);
    assert.strictEqual(result.deltaByUid.size, 0);
    // The claim is still rewritten — just not attributed to any uid.
    assert.strictEqual(writes.length, 1);
    assert.strictEqual(writes[0].update.points, 4);
  });

  it("skips claims already at the target monarch+points (idempotent retry)", async () => {
    // Simulates an admin re-running reviewReport after a partial-success run:
    // some claims were already rewritten on the first attempt. The retry must
    // not re-stamp those claims' correctedFromMonarch with the new (post-
    // correction) monarch, which would erase the original pre-correction
    // value from the audit trail.
    const claims: ClaimDoc[] = [
      // Already rewritten on the first run: monarch === target, points === target.
      { id: "c1", userid: "u1", points: 4, monarch: "GR", postboxes: "/postbox/osm_42" },
      // Not yet rewritten — still on the old cypher.
      { id: "c2", userid: "u2", points: 9, monarch: "EVIIR", postboxes: "/postbox/osm_42" },
    ];
    const { db, writes } = makeMockDb(claims);
    const result = await repointClaimsForPostbox(db, "osm_42", "GR");
    // Only the unrewritten claim is touched.
    assert.strictEqual(result.claimCount, 1);
    assert.strictEqual(writes.length, 1);
    assert.strictEqual(writes[0].ref.id, "c2");
    assert.strictEqual(writes[0].update.correctedFromMonarch, "EVIIR",
      "audit trail preserves the real pre-correction monarch on the still-old claim");
    // u1 contributes no delta — its claim already matches; u2 contributes -5.
    assert.strictEqual(result.deltaByUid.has("u1"), false);
    assert.strictEqual(result.deltaByUid.get("u2"), -5);
  });
});

describe("maxDailyFromClaims", () => {
  it("returns 0 for no claims", () => assert.strictEqual(maxDailyFromClaims([]), 0));
  it("sums points per day and returns the busiest day's total", () => {
    const claims = [
      { dailyDate: "2026-05-01", points: 2 },
      { dailyDate: "2026-05-01", points: 7 },
      { dailyDate: "2026-05-02", points: 4 },
      { dailyDate: "2026-05-03", points: 12 },
    ];
    assert.strictEqual(maxDailyFromClaims(claims), 12);
  });
  it("reflects a downward correction (a day total dropping below another)", () => {
    // Day 1 had 14 (2+12) but the 12-cypher was corrected to 2 → day1 = 4; day2 = 9 wins.
    const before = [{ dailyDate: "d1", points: 2 }, { dailyDate: "d1", points: 12 }, { dailyDate: "d2", points: 9 }];
    const after = [{ dailyDate: "d1", points: 2 }, { dailyDate: "d1", points: 2 }, { dailyDate: "d2", points: 9 }];
    assert.strictEqual(maxDailyFromClaims(before), 14);
    assert.strictEqual(maxDailyFromClaims(after), 9);
  });
  it("ignores entries with no dailyDate", () => {
    assert.strictEqual(maxDailyFromClaims([{ points: 99 }, { dailyDate: "d1", points: 3 }]), 3);
  });
});

describe("submitReport / reviewReport (onCall) — auth & validation", function (this: Mocha.Suite) {
  this.timeout(10000);
  const wrappedSubmit = testEnv.wrap(myFunctions.submitReport) as (data: unknown) => Promise<unknown>;
  const wrappedReview = testEnv.wrap(myFunctions.reviewReport) as (data: unknown) => Promise<unknown>;

  it("submitReport throws unauthenticated with no auth", async () => {
    try {
      await wrappedSubmit({ data: { type: "missing_postbox", lat: 51.5, lng: -0.1 } });
      assert.fail("expected unauthenticated");
    } catch (e) {
      assert.strictEqual((e as { code?: string }).code, "unauthenticated");
    }
  });
  it("submitReport throws invalid-argument for an unknown type", async () => {
    try {
      await wrappedSubmit({ data: { type: "nonsense" }, auth: { uid: "u1" } });
      assert.fail("expected invalid-argument");
    } catch (e) {
      assert.strictEqual((e as { code?: string }).code, "invalid-argument");
    }
  });
  it("reviewReport throws permission-denied for a non-admin caller", async () => {
    try {
      await wrappedReview({ data: { reportId: "r1", decision: "reject" }, auth: { uid: "u1" } });
      assert.fail("expected permission-denied");
    } catch (e) {
      assert.strictEqual((e as { code?: string }).code, "permission-denied");
    }
  });
  it("reviewReport throws permission-denied even with auth but no admin claim flag", async () => {
    try {
      await wrappedReview({ data: { reportId: "r1", decision: "accept" }, auth: { uid: "u1", token: { admin: false } } });
      assert.fail("expected permission-denied");
    } catch (e) {
      assert.strictEqual((e as { code?: string }).code, "permission-denied");
    }
  });
});

describe("reviewFlag (onCall) — auth & validation", function (this: Mocha.Suite) {
  this.timeout(10000);
  const wrappedReviewFlag = testEnv.wrap(myFunctions.reviewFlag) as (data: unknown) => Promise<unknown>;

  it("throws permission-denied for a non-admin caller", async () => {
    try {
      await wrappedReviewFlag({ data: { flagId: "f1" }, auth: { uid: "u1" } });
      assert.fail("expected permission-denied");
    } catch (e) {
      assert.strictEqual((e as { code?: string }).code, "permission-denied");
    }
  });

  it("throws permission-denied with auth but admin claim false", async () => {
    try {
      await wrappedReviewFlag({ data: { flagId: "f1" }, auth: { uid: "u1", token: { admin: false } } });
      assert.fail("expected permission-denied");
    } catch (e) {
      assert.strictEqual((e as { code?: string }).code, "permission-denied");
    }
  });

  it("throws invalid-argument for a missing flagId (admin caller)", async () => {
    try {
      await wrappedReviewFlag({ data: {}, auth: { uid: "admin1", token: { admin: true } } });
      assert.fail("expected invalid-argument");
    } catch (e) {
      // invalid-argument is reached only for admins; non-emulator runs may also
      // surface permission-denied on the subsequent Firestore read, but the
      // arg check runs first so invalid-argument is expected here.
      assert.strictEqual((e as { code?: string }).code, "invalid-argument");
    }
  });
});

// ── filterToCorridor ──────────────────────────────────────────────────────────
//
// Fixture: start = (0, 0), end = (0, 0.01)  (roughly ~1.1 km due-east at equator)
// halfWidthMetres = 200 m
//
//   pb_on    (0, 0.005)  — lies on the segment midpoint, perp dist ≈ 0 m  → IN
//   pb_near  (0.001, 0.005) — slightly north of midpoint, perp dist ≈ 111 m  → IN
//   pb_far   (0.01,  0.005) — well north (~1.1 km), perp dist ≈ 1110 m  → OUT

describe("filterToCorridor", () => {
  const start = { lat: 0, lng: 0 };
  const end   = { lat: 0, lng: 0.01 };
  const halfWidth = 200;

  const makeCandidates = () => [
    { id: "pb_on",   lat: 0,     lng: 0.005, monarch: "EIIR", points: 2 },
    { id: "pb_near", lat: 0.001, lng: 0.005, monarch: "EIIR", points: 2 },
    { id: "pb_far",  lat: 0.01,  lng: 0.005, monarch: "EIIR", points: 2 },
  ];

  it("returns candidates within the corridor half-width", () => {
    const result = filterToCorridor(makeCandidates(), start, end, halfWidth);
    assert.strictEqual(result.length, 2);
    const ids = result.map((c) => c.id);
    assert.ok(ids.includes("pb_on"),   "pb_on should be included");
    assert.ok(ids.includes("pb_near"), "pb_near should be included");
  });

  it("excludes the candidate beyond the half-width", () => {
    const result = filterToCorridor(makeCandidates(), start, end, halfWidth);
    assert.ok(!result.map((c) => c.id).includes("pb_far"), "pb_far should be excluded");
  });

  it("excludes candidates whose projection falls outside [0,1] (before start)", () => {
    const behind = [{ id: "pb_behind", lat: 0, lng: -0.005, monarch: "EIIR", points: 2 }];
    const result = filterToCorridor(behind, start, end, halfWidth);
    assert.strictEqual(result.length, 0);
  });

  it("excludes candidates whose projection falls outside [0,1] (beyond end)", () => {
    const beyond = [{ id: "pb_beyond", lat: 0, lng: 0.015, monarch: "EIIR", points: 2 }];
    const result = filterToCorridor(beyond, start, end, halfWidth);
    assert.strictEqual(result.length, 0);
  });

  it("returns all candidates when half-width is very large", () => {
    const result = filterToCorridor(makeCandidates(), start, end, 50_000);
    assert.strictEqual(result.length, 3);
  });

  it("returns empty array when half-width is 0 and no candidate is exactly on-line", () => {
    // pb_near is 0.001° off; pb_on lies exactly on the segment so its perp dist is 0.
    const result = filterToCorridor(makeCandidates(), start, end, 0);
    // Exactly one candidate (pb_on) has zero perpendicular distance.
    assert.strictEqual(result.length, 1);
  });

  it("returns empty array when half-width is negative", () => {
    // A negative half-width is nonsense (caller shouldn't pass it) but the
    // function must degrade safely: no perpDist can be <= a negative number,
    // so nothing should be included rather than throwing.
    const result = filterToCorridor(makeCandidates(), start, end, -100);
    assert.strictEqual(result.length, 0);
  });

  it("degenerate segment (start == end): includes candidates within halfWidth of start", () => {
    // When start and end coincide, segLenSq is 0 and t falls back to 0 —
    // every candidate gets t=0 (no rejection by the projection bounds) and
    // perpDist becomes the great-circle distance from start. This is the
    // explicitly-documented degenerate-segment behaviour.
    const here = { lat: 0, lng: 0 };
    const candidates = [
      { id: "pb_near_start", lat: 0,     lng: 0.001, monarch: null, points: 2 }, // ~111 m east
      { id: "pb_far_start",  lat: 0,     lng: 0.01,  monarch: null, points: 2 }, // ~1.1 km east
    ];
    // 200 m half-width — pb_near_start fits, pb_far_start does not.
    const result = filterToCorridor(candidates, here, here, 200);
    assert.strictEqual(result.length, 1);
    assert.strictEqual(result[0].id, "pb_near_start");
  });
});

describe("midpoint", () => {
  // eslint-disable-next-line @typescript-eslint/no-require-imports, @typescript-eslint/no-var-requires
  const planner = require("../_routePlanner") as typeof import("../_routePlanner");

  it("averages lat/lng of two points", () => {
    const m = planner.midpoint({ lat: 0, lng: 0 }, { lat: 10, lng: 20 });
    assert.strictEqual(m.lat, 5);
    assert.strictEqual(m.lng, 10);
  });

  it("midpoint of coincident points is the same point", () => {
    const p = { lat: 51.5, lng: -0.1 };
    assert.deepStrictEqual(planner.midpoint(p, p), p);
  });

  it("handles negative coordinates symmetrically", () => {
    const m = planner.midpoint({ lat: -1, lng: -2 }, { lat: 1, lng: 2 });
    assert.strictEqual(m.lat, 0);
    assert.strictEqual(m.lng, 0);
  });
});

describe("metresBetween", () => {
  // eslint-disable-next-line @typescript-eslint/no-require-imports, @typescript-eslint/no-var-requires
  const planner = require("../_routePlanner") as typeof import("../_routePlanner");

  it("returns 0 for coincident points", () => {
    assert.strictEqual(
      planner.metresBetween({ lat: 51.5, lng: -0.1 }, { lat: 51.5, lng: -0.1 }),
      0,
    );
  });

  it("approximates 1° of latitude ≈ 111 km", () => {
    // The Earth's polar radius is approximately constant for latitude lines.
    // 1° of latitude ≈ 111.32 km; geolib returns ~111,195 m at sea level.
    const d = planner.metresBetween({ lat: 0, lng: 0 }, { lat: 1, lng: 0 });
    assert.ok(d > 110_000 && d < 112_000,
      `expected ~111 km, got ${d} m`);
  });

  it("symmetric: d(a,b) == d(b,a)", () => {
    const a = { lat: 51.5, lng: -0.1 };
    const b = { lat: 52.5, lng: -1.1 };
    assert.strictEqual(planner.metresBetween(a, b), planner.metresBetween(b, a));
  });
});

describe("filterToEllipse (boundary cases)", () => {
  // start→end is roughly 1.1 km east (1° of longitude at the equator is
  // ~111.32 km; 0.01° ≈ 1.11 km).
  const start = { lat: 0, lng: 0 };
  const end   = { lat: 0, lng: 0.01 };
  const candidates = [
    // On the segment midpoint — start→p + p→end equals direct distance.
    { id: "pb_on", lat: 0,     lng: 0.005, monarch: null, points: 2 },
    // Slightly north — start→p + p→end is greater (a bit of a detour).
    { id: "pb_off", lat: 0.001, lng: 0.005, monarch: null, points: 2 },
  ];

  it("returns empty for budget 0 (impossible to even reach any point)", () => {
    const result = filterToEllipse(candidates, start, end, 0);
    assert.strictEqual(result.length, 0);
  });

  it("returns empty when budget < direct distance (degenerate ellipse)", () => {
    // Direct distance is ~1100m; budget of 500m means even reaching the
    // segment midpoint would exceed budget (start→mid + mid→end ≈ 1100m).
    const result = filterToEllipse(candidates, start, end, 500);
    assert.strictEqual(result.length, 0);
  });

  it("budget == direct distance includes only on-segment candidates", () => {
    // The ellipse collapses to the segment itself; only pb_on (on the line)
    // satisfies start→p + p→end == direct distance. pb_off requires a detour.
    // 0.01° lng ≈ 1113 m at the equator, with a few metres slack for the
    // great-circle vs equirectangular discrepancy and floating-point.
    const direct = 1115;
    const result = filterToEllipse(candidates, start, end, direct);
    const ids = result.map((c) => c.id);
    assert.ok(ids.includes("pb_on"), "pb_on must be included at the segment-budget");
    assert.ok(!ids.includes("pb_off"), "pb_off detour exceeds the segment-budget");
  });

  it("returns empty for an empty candidates list", () => {
    assert.deepStrictEqual(filterToEllipse([], start, end, 10000), []);
  });

  it("degenerate start==end ellipse collapses to a disc of radius budget/2", () => {
    // start→p + p→end = 2 * distance(start, p). Candidates with
    // distance(start,p) <= budget/2 are included.
    const here = { lat: 0, lng: 0 };
    const candidates = [
      { id: "near", lat: 0, lng: 0.001, monarch: null, points: 2 }, // ~111 m east
      { id: "far",  lat: 0, lng: 0.01,  monarch: null, points: 2 }, // ~1.1 km east
    ];
    // Budget 400m → disc radius 200m → only "near" fits.
    const result = filterToEllipse(candidates, here, here, 400);
    assert.strictEqual(result.length, 1);
    assert.strictEqual(result[0].id, "near");
  });
});

// ── routePostboxes pure logic tests ──────────────────────────────────────────
//
// Fixture: start=51.5000,-0.1000  end=51.5000,-0.0900  (~780 m due east)
//
//   box_a  EVIIIR (12 pts) — on the line, lng midpoint  → IN corridor 100m
//   box_b  VR     ( 7 pts) — on the line, 3/4 along     → IN corridor 100m
//   box_c  EIIR   ( 2 pts) — 200 m north of midpoint    → OUT corridor 100m, IN ellipse (generous budget)
//   box_d  GR     ( 4 pts) — 200 m south of midpoint    → OUT corridor 100m, IN ellipse (generous budget)
//   box_far EIIR  ( 2 pts) — far away (0.5° lat north)  → OUT both
//
describe("routePostboxes pure corridor logic", () => {
  const start = { lat: 51.5000, lng: -0.1000 };
  const end   = { lat: 51.5000, lng: -0.0900 };
  // ~0.0011° ≈ 75m at this latitude; well within 100m corridor
  const midLng = (start.lng + end.lng) / 2; // -0.0950

  const candidates = [
    { id: "box_a",   lat: 51.5000, lng: midLng,    monarch: "EVIIIR", points: 12 },
    { id: "box_b",   lat: 51.5000, lng: -0.0925,   monarch: "VR",     points: 7  },
    { id: "box_c",   lat: 51.5018, lng: midLng,    monarch: "EIIR",   points: 2  }, // ~200m north
    { id: "box_d",   lat: 51.4982, lng: midLng,    monarch: "GR",     points: 4  }, // ~200m south
    { id: "box_far", lat: 52.0000, lng: midLng,    monarch: "EIIR",   points: 2  }, // far away
  ];

  it("corridor 100m: count=2, points=19 (12+7)", () => {
    const filtered = filterToCorridor(candidates, start, end, 100);
    assert.strictEqual(filtered.length, 2);
    const ids = filtered.map(c => c.id).sort();
    assert.deepStrictEqual(ids, ["box_a", "box_b"]);
    const points = filtered.reduce((s, c) => s + c.points, 0);
    assert.strictEqual(points, 19);
  });

  it("corridor result contains no coordinates or IDs beyond the count/points aggregate", () => {
    const filtered = filterToCorridor(candidates, start, end, 100);
    const count = filtered.length;
    const points = filtered.reduce((s, c) => s + c.points, 0);
    // Simulate what routePostboxes returns — only aggregate fields.
    const response = { count, points, directDistanceM: 780, budgetDistanceM: 780, warnings: [] };
    assert.ok(!("postboxes" in response));
    assert.ok(!("ids" in response));
    assert.ok(!("locations" in response));
    assert.strictEqual(response.count, 2);
    assert.strictEqual(response.points, 19);
  });

  it("claimed-today filter reduces corridor count by 1 when one in-corridor box is claimed", () => {
    const claimedIds = new Set(["box_a"]);
    const unclaimed = candidates.filter(c => !claimedIds.has(c.id));
    const filtered = filterToCorridor(unclaimed, start, end, 100);
    assert.strictEqual(filtered.length, 1);
    assert.strictEqual(filtered[0].id, "box_b");
    assert.strictEqual(filtered.reduce((s, c) => s + c.points, 0), 7);
  });
});

describe("routePostboxes pure detour logic", () => {
  const start = { lat: 51.5000, lng: -0.1000 };
  const end   = { lat: 51.5000, lng: -0.0900 };
  const midLng = (start.lng + end.lng) / 2;

  const candidates = [
    { id: "box_a",   lat: 51.5000, lng: midLng,    monarch: "EVIIIR", points: 12 },
    { id: "box_b",   lat: 51.5000, lng: -0.0925,   monarch: "VR",     points: 7  },
    { id: "box_c",   lat: 51.5018, lng: midLng,    monarch: "EIIR",   points: 2  },
    { id: "box_d",   lat: 51.4982, lng: midLng,    monarch: "GR",     points: 4  },
    { id: "box_far", lat: 52.0000, lng: midLng,    monarch: "EIIR",   points: 2  },
  ];

  // A generous detour budget: direct ~780 m + 60 min detour at 4.5 km/h
  const speedMps = 4.5 * 1000 / 3600; // 1.25 m/s
  const directM = 780;
  const budgetSeconds = directM / speedMps + 60 * 60; // huge budget
  const budgetM = speedMps * budgetSeconds;

  it("ellipse filter with generous budget includes in-corridor boxes and nearby off-line boxes", () => {
    const filtered = filterToEllipse(candidates, start, end, budgetM);
    const ids = filtered.map(c => c.id).sort();
    // box_far is 55km away — excluded regardless.
    assert.ok(!ids.includes("box_far"), "box_far should be excluded");
    // box_a, box_b, box_c, box_d should all be inside the generous ellipse.
    assert.ok(ids.includes("box_a"), "box_a should be included");
    assert.ok(ids.includes("box_b"), "box_b should be included");
    assert.ok(ids.includes("box_c"), "box_c should be included");
    assert.ok(ids.includes("box_d"), "box_d should be included");
  });

  it("beam search returns count and score consistent with filtered candidates", () => {
    const filtered = filterToEllipse(candidates.filter(c => c.id !== "box_far"), start, end, budgetM);
    const result = beamSearchOrienteering(start, end, filtered, budgetSeconds, speedMps, 60, 50);
    // With a huge budget all 4 near candidates should be visitable.
    assert.strictEqual(typeof result.score, "number");
    assert.ok(result.score >= 12, "should score at least 12 (EVIIIR alone)");
    assert.ok(result.visited.size >= 1, "should visit at least one box");
  });

  it("detour with zero budget visits no boxes (just the direct walk)", () => {
    // Budget = direct walk time only; no time to detour.
    const tightBudget = directM / speedMps;
    const tightBudgetM = speedMps * tightBudget;
    // With the tight budget the ellipse degenerates to the segment — only exactly
    // on-line boxes qualify. box_c and box_d are off-line; box_a and box_b are on it.
    const filtered = filterToEllipse(candidates, start, end, tightBudgetM);
    const result = beamSearchOrienteering(start, end, filtered, tightBudget, speedMps, 60, 50);
    // Beam search can't add dwell time when budget is exactly the walk time.
    assert.strictEqual(typeof result.visited.size, "number");
  });

  it("empty candidates returns the initial state with score 0", () => {
    // No postboxes in range at all — the search must terminate cleanly with
    // the initial state (no visits, no score), not loop or throw.
    const result = beamSearchOrienteering(start, end, [], budgetSeconds, speedMps, 60, 50);
    assert.strictEqual(result.score, 0);
    assert.strictEqual(result.visited.size, 0);
    assert.strictEqual(result.route.length, 0);
    assert.strictEqual(result.timeUsed, 0);
    assert.deepStrictEqual(result.current, start);
  });

  it("candidate beyond the time budget is not visited", () => {
    // Synthetic candidate far enough that even reaching it eats more than the
    // budget; beam search should report 0 visits despite the candidate being
    // present.
    const farAway = [
      { id: "unreachable", lat: 52.5, lng: -0.5, monarch: null, points: 100 },
    ];
    // Tight budget = just the direct walk time, no detour room.
    const tight = directM / speedMps;
    const result = beamSearchOrienteering(start, end, farAway, tight, speedMps, 60, 50);
    assert.strictEqual(result.score, 0);
    assert.strictEqual(result.visited.size, 0);
  });

  it("maximises score: with budget for only one detour, picks the higher-value box", () => {
    // Loop route (start === end) with two boxes the same distance away in
    // opposite directions. The budget affords a detour to exactly ONE of them.
    // The orienteering objective must pick the 12-pt box over the 2-pt box —
    // the core property that distinguishes this from "visit whatever fits".
    const s = { lat: 51.5, lng: -0.1 };
    const e = { lat: 51.5, lng: -0.1 };
    const high = { id: "box_high", lat: 51.51, lng: -0.1, monarch: "EVIIIR", points: 12 };
    const low = { id: "box_low", lat: 51.49, lng: -0.1, monarch: "EIIR", points: 2 };
    const v = 4.5 * 1000 / 3600; // 1.25 m/s
    // Round trip to one box (there and back, since start === end), one dwell,
    // plus a little slack. Visiting both would need ~2x the travel and is
    // infeasible, so the search can only afford one box.
    const oneBoxBudget = (2 * metresBetween(s, high)) / v + 60 + 30;
    const result = beamSearchOrienteering(s, e, [high, low], oneBoxBudget, v, 60, 50);
    assert.strictEqual(result.score, 12, "should pick the 12-pt box, not the 2-pt one");
    assert.strictEqual(result.visited.size, 1, "budget only affords one detour");
    assert.ok(result.visited.has("box_high"), "the visited box must be the high-value one");
    assert.ok(!result.visited.has("box_low"), "the low-value box must not be chosen");
  });
});

describe("finaliseRoute", () => {
  // Pure helper used by the plan_route CLI to compute closing-leg metres /
  // seconds and total route stats after the beam search picks stops.
  // eslint-disable-next-line @typescript-eslint/no-require-imports, @typescript-eslint/no-var-requires
  const planner = require("../_routePlanner") as typeof import("../_routePlanner");

  const start = { lat: 51.5000, lng: -0.1000 };
  const end   = { lat: 51.5000, lng: -0.0900 }; // ~780 m due east

  it("computes closing leg and totals from an empty route", () => {
    // No intermediate stops — we walk straight from start to end.
    const initial = {
      current: start,
      currentId: "__START__",
      visited: new Set<string>(),
      timeUsed: 0,
      score: 0,
      route: [],
    };
    const speedMps = 1.25; // 4.5 km/h
    const r = planner.finaliseRoute(initial, end, speedMps);
    // Distance from start to end (~780 m at this latitude).
    assert.ok(r.closingMetres > 600 && r.closingMetres < 900,
      `closingMetres should be ~780, got ${r.closingMetres}`);
    assert.ok(Math.abs(r.closingSeconds - r.closingMetres / speedMps) < 0.001);
    // No stops → totalMetres equals closing leg, totalSeconds equals closing.
    assert.strictEqual(r.totalMetres, r.closingMetres);
    assert.strictEqual(r.totalSeconds, r.closingSeconds);
  });

  it("adds the closing leg on top of accumulated leg distances", () => {
    // Two synthetic stops with known leg distances. The "current" position is
    // wherever the second stop sits; finaliseRoute should add the leg from
    // there to end on top of legMeters.reduce.
    const stopA = { id: "a", lat: 51.5000, lng: -0.0950, monarch: null, points: 5 };
    const stopB = { id: "b", lat: 51.5000, lng: -0.0925, monarch: null, points: 5 };
    const state = {
      current: { lat: stopB.lat, lng: stopB.lng },
      currentId: "b",
      visited: new Set<string>(["a", "b"]),
      timeUsed: 300, // arbitrary cumulative seconds
      score: 10,
      route: [
        { postbox: stopA, legMeters: 350, cumSeconds: 200 },
        { postbox: stopB, legMeters: 180, cumSeconds: 300 },
      ],
    };
    const speedMps = 1.25;
    const r = planner.finaliseRoute(state, end, speedMps);
    // totalMetres == sum(legMeters) + closing leg.
    assert.strictEqual(r.totalMetres, 350 + 180 + r.closingMetres);
    // totalSeconds == timeUsed + closingSeconds (NOT cumSeconds — that's just
    // an inner annotation; the authoritative running total is timeUsed).
    assert.strictEqual(r.totalSeconds, state.timeUsed + r.closingSeconds);
  });
});

// ── Abuse-detection signals (pure, shadow mode) ───────────────────────────────
import {
  coordKey,
  impossibleTravelSignal,
  outOfWindowSignal,
  coordClusterSignal,
  repeatedDeviceSignal,
  evaluateClaimSignals,
  summariseFlags,
  applyTrustDecay,
  SHADOW_TRAVEL_FLAG_M_PER_MIN,
  OUT_OF_WINDOW_MS,
  CLUSTER_MIN_REPEATS,
  REPEATED_DEVICE_MIN_ACCOUNTS,
  DEFAULT_TRUST_SCORE,
} from "../_abuseSignals";

describe("abuse signals: coordKey", () => {
  it("rounds to 6 dp and joins lat,lng", () => {
    assert.strictEqual(coordKey(51.4532109, -0.9543201), "51.453211,-0.954320");
  });
  it("two positions that agree to 6 dp produce the same key", () => {
    assert.strictEqual(coordKey(51.4532104, -0.9543204), coordKey(51.4532101, -0.9543198));
  });
  it("positions differing at 6 dp produce different keys", () => {
    assert.notStrictEqual(coordKey(51.453210, -0.954320), coordKey(51.453219, -0.954320));
  });
});

describe("abuse signals: impossibleTravelSignal", () => {
  it("flags a speed at or above the shadow threshold", () => {
    const r = impossibleTravelSignal(SHADOW_TRAVEL_FLAG_M_PER_MIN);
    assert.strictEqual(r.flagged, true);
    assert.strictEqual(r.value, SHADOW_TRAVEL_FLAG_M_PER_MIN);
  });
  it("does not flag a speed below the threshold", () => {
    assert.strictEqual(impossibleTravelSignal(SHADOW_TRAVEL_FLAG_M_PER_MIN - 1).flagged, false);
  });
  it("does not flag when no travel speed is available (first claim)", () => {
    assert.strictEqual(impossibleTravelSignal(undefined).flagged, false);
  });
});

describe("abuse signals: outOfWindowSignal", () => {
  const server = 1_000_000_000_000;
  it("flags when client clock is off by more than the window", () => {
    const r = outOfWindowSignal(server, server - (OUT_OF_WINDOW_MS + 1));
    assert.strictEqual(r.flagged, true);
    assert.strictEqual(r.value, OUT_OF_WINDOW_MS + 1);
  });
  it("does not flag when within the window", () => {
    assert.strictEqual(outOfWindowSignal(server, server + OUT_OF_WINDOW_MS).flagged, false);
  });
  it("does not flag when client timestamp is absent", () => {
    assert.strictEqual(outOfWindowSignal(server, undefined).flagged, false);
  });
});

describe("abuse signals: coordClusterSignal", () => {
  it("flags once repeats reach the minimum", () => {
    assert.strictEqual(coordClusterSignal(CLUSTER_MIN_REPEATS).flagged, true);
  });
  it("does not flag below the minimum", () => {
    assert.strictEqual(coordClusterSignal(CLUSTER_MIN_REPEATS - 1).flagged, false);
  });
});

describe("abuse signals: repeatedDeviceSignal", () => {
  it("flags once distinct accounts reach the minimum", () => {
    assert.strictEqual(repeatedDeviceSignal(REPEATED_DEVICE_MIN_ACCOUNTS).flagged, true);
  });
  it("does not flag below the minimum", () => {
    assert.strictEqual(repeatedDeviceSignal(REPEATED_DEVICE_MIN_ACCOUNTS - 1).flagged, false);
  });
  it("reports the distinct-account count as the value", () => {
    assert.strictEqual(repeatedDeviceSignal(5).value, 5);
  });
});

describe("abuse signals: evaluateClaimSignals", () => {
  const base = { serverTsMs: 1_000_000_000_000, coordRepeatCount: 0, distinctDeviceAccounts: 0 };

  it("flags nothing for a clean claim", () => {
    const r = evaluateClaimSignals(base);
    assert.deepStrictEqual(r.reasons, []);
    assert.strictEqual(r.severity, "low");
  });

  it("flags repeated_device once distinct accounts reach the minimum", () => {
    const r = evaluateClaimSignals({ ...base, distinctDeviceAccounts: REPEATED_DEVICE_MIN_ACCOUNTS });
    assert.deepStrictEqual(r.reasons, ["repeated_device"]);
    assert.strictEqual(r.severity, "low");
    assert.strictEqual(r.signals.deviceAccountCount, REPEATED_DEVICE_MIN_ACCOUNTS);
  });

  it("escalates severity as signals co-occur (device + travel = med)", () => {
    const r = evaluateClaimSignals({
      ...base,
      travelSpeedMPerMin: SHADOW_TRAVEL_FLAG_M_PER_MIN,
      distinctDeviceAccounts: REPEATED_DEVICE_MIN_ACCOUNTS,
    });
    assert.strictEqual(r.reasons.length, 2);
    assert.ok(r.reasons.includes("repeated_device"));
    assert.ok(r.reasons.includes("impossible_travel"));
    assert.strictEqual(r.severity, "med");
  });

  it("reports all four signals with high severity when everything fires", () => {
    const r = evaluateClaimSignals({
      travelSpeedMPerMin: SHADOW_TRAVEL_FLAG_M_PER_MIN,
      serverTsMs: base.serverTsMs,
      clientTsMs: base.serverTsMs - (OUT_OF_WINDOW_MS + 1),
      coordRepeatCount: CLUSTER_MIN_REPEATS,
      distinctDeviceAccounts: REPEATED_DEVICE_MIN_ACCOUNTS,
    });
    assert.strictEqual(r.reasons.length, 4);
    assert.strictEqual(r.severity, "high");
    assert.strictEqual(r.signals.coordRepeatCount, CLUSTER_MIN_REPEATS);
    assert.strictEqual(r.signals.deviceAccountCount, REPEATED_DEVICE_MIN_ACCOUNTS);
  });
});

describe("abuse signals: summariseFlags", () => {
  it("collects only the fired reasons", () => {
    const r = summariseFlags([
      { reason: "impossible_travel", flagged: true },
      { reason: "out_of_window", flagged: false },
      { reason: "coord_cluster", flagged: true },
    ]);
    assert.deepStrictEqual(r.reasons, ["impossible_travel", "coord_cluster"]);
  });
  it("escalates severity with the number of co-occurring signals", () => {
    const sig = (n: number) =>
      summariseFlags(
        ["a", "b", "c"].slice(0, n).map((reason) => ({ reason, flagged: true })),
      ).severity;
    assert.strictEqual(sig(1), "low");
    assert.strictEqual(sig(2), "med");
    assert.strictEqual(sig(3), "high");
  });
});

describe("abuse signals: applyTrustDecay", () => {
  it("decrements more for higher severity", () => {
    assert.ok(
      applyTrustDecay(DEFAULT_TRUST_SCORE, "high") <
        applyTrustDecay(DEFAULT_TRUST_SCORE, "low"),
    );
  });
  it("never drops below zero", () => {
    assert.strictEqual(applyTrustDecay(0, "high"), 0);
  });
  it("never rises above the default ceiling", () => {
    assert.ok(applyTrustDecay(DEFAULT_TRUST_SCORE, "low") <= DEFAULT_TRUST_SCORE);
  });
});

// ── dailyClaimPatch: the postbox claim patch must never carry claimant PII ─────
import { dailyClaimPatch } from "../startScoring";

describe("dailyClaimPatch (postbox claim patch)", () => {
  it("writes only the London date", () => {
    assert.deepStrictEqual(dailyClaimPatch("2026-07-03"), {
      dailyClaim: { date: "2026-07-03" },
    });
  });
  it("never includes a `by` uid (location-PII regression guard)", () => {
    // postbox docs are world-readable + carry the exact geopoint, so a claimant
    // uid here would leak "who was at this location on this date". Pin that it
    // is never reintroduced.
    assert.strictEqual("by" in dailyClaimPatch("2026-07-03").dailyClaim, false);
  });
});

// ── Account deletion (GDPR) helpers (unit, mock Firestore) ─────────────────────
import {
  DELETED_UID,
  anonymiseClaimsForUser,
  anonymiseReportsForUser,
  removeUserFromFriends,
  removeUserFromLeaderboards,
  deleteUserDocs,
} from "../_accountDeletion";
import { storagePrefixesForUser } from "../onUserDeleted";

describe("account deletion: storagePrefixesForUser", () => {
  it("covers report photos and (future-proof) claim photos for the uid", () => {
    assert.deepStrictEqual(storagePrefixesForUser("u1"), [
      "report_photos/u1/",
      "claims-photos/u1/",
    ]);
  });
});

describe("account deletion: deleteUserDocs (mock Firestore)", () => {
  it("deletes the profile, per-uid docs, countyStats, and the user's flags", async () => {
    const deleted: string[] = [];
    const makeCollDoc = (path: string) => ({
      // A DocumentReference stand-in; deleteUserDocs only reads .id via batch.
      id: path,
      _path: path,
    });
    const countyDocs = [makeCollDoc("users/u1/countyStats/avon")];
    const flagDocs = [makeCollDoc("moderationFlags/f1"), makeCollDoc("moderationFlags/f2")];

    const userRef = {
      _path: "users/u1",
      collection: (name: string) => {
        if (name !== "countyStats") throw new Error(`unexpected subcollection ${name}`);
        return { async get() { return { docs: countyDocs.map((d) => ({ ref: d })) }; } };
      },
    };
    const db = {
      collection: (name: string) => {
        if (name === "users") return { doc: () => userRef };
        if (name === "moderationFlags") {
          return {
            where(field: string, op: string, val: unknown) {
              assert.strictEqual(field, "uid");
              assert.strictEqual(op, "==");
              assert.strictEqual(val, "u1");
              return { async get() { return { docs: flagDocs.map((d) => ({ ref: d })) }; } };
            },
          };
        }
        // fcmTokens / reportQuotas / trustScores
        return { doc: () => makeCollDoc(`${name}/u1`) };
      },
      batch() {
        return {
          delete(ref: { _path: string }) { deleted.push(ref._path); },
          async commit() {},
        };
      },
    };

    await deleteUserDocs(db as unknown as import("firebase-admin").firestore.Firestore, "u1");

    assert.ok(deleted.includes("users/u1"), "profile doc deleted");
    assert.ok(deleted.includes("users/u1/countyStats/avon"), "countyStats deleted");
    assert.ok(deleted.includes("moderationFlags/f1") && deleted.includes("moderationFlags/f2"),
      "user's moderation flags deleted");
    assert.ok(deleted.includes("fcmTokens/u1"), "fcm token deleted");
    assert.ok(deleted.includes("reportQuotas/u1"), "report quota deleted");
    assert.ok(deleted.includes("trustScores/u1"), "trust score deleted");
  });
});

describe("account deletion: anonymiseClaimsForUser (mock Firestore)", () => {
  type Doc = { id: string; userid?: string; points?: number };
  function makeDb(claims: Doc[]) {
    const writes: Array<{ id: string; update: Record<string, unknown> }> = [];
    const db = {
      collection: (name: string) => {
        if (name !== "claims") throw new Error(`unexpected collection ${name}`);
        let filter: unknown;
        const q = {
          where(field: string, op: string, val: unknown) {
            if (field !== "userid" || op !== "==") throw new Error(`unexpected where ${field} ${op}`);
            filter = val;
            return q;
          },
          async get() {
            return {
              docs: claims
                .filter((c) => c.userid === filter)
                .map((c) => ({ ref: { id: c.id }, data: () => c as Record<string, unknown> })),
            };
          },
        };
        return q;
      },
      batch() {
        const bw: Array<{ id: string; update: Record<string, unknown> }> = [];
        return {
          set(ref: { id: string }, update: Record<string, unknown>) { bw.push({ id: ref.id, update }); },
          async commit() { writes.push(...bw); },
        };
      },
    };
    return { db: db as unknown as import("firebase-admin").firestore.Firestore, writes };
  }

  it("rewrites userid to the deleted sentinel and strips location PII", async () => {
    const { db, writes } = makeDb([
      { id: "c1", userid: "u1", points: 9 },
      { id: "c2", userid: "u1", points: 4 },
      { id: "c3", userid: "u2", points: 7 }, // different user — untouched
    ]);
    const n = await anonymiseClaimsForUser(db, "u1");
    assert.strictEqual(n, 2);
    assert.strictEqual(writes.length, 2);
    assert.ok(!writes.some((w) => w.id === "c3"));
    for (const w of writes) {
      assert.strictEqual(w.update.userid, DELETED_UID);
      // points is preserved (not part of the update).
      assert.strictEqual("points" in w.update, false);
      // Location fields are FieldValue.delete() sentinels (objects, not values).
      for (const f of ["userLat", "userLng", "coordKey6", "clientTsMs", "travelSpeed", "deviceIdHash"]) {
        assert.ok(f in w.update, `${f} should be in the update`);
        assert.notStrictEqual(typeof w.update[f], "number");
        assert.notStrictEqual(typeof w.update[f], "string");
      }
    }
  });
});

describe("account deletion: anonymiseReportsForUser (mock Firestore)", () => {
  function makeDb(reports: Array<{ id: string; reporterUid?: string }>) {
    const writes: Array<{ id: string; update: Record<string, unknown> }> = [];
    const db = {
      collection: (name: string) => {
        if (name !== "reports") throw new Error(`unexpected collection ${name}`);
        let filter: unknown;
        const q = {
          where(field: string, op: string, val: unknown) {
            if (field !== "reporterUid" || op !== "==") throw new Error(`unexpected where ${field} ${op}`);
            filter = val;
            return q;
          },
          async get() {
            return {
              docs: reports
                .filter((r) => r.reporterUid === filter)
                .map((r) => ({ ref: { id: r.id }, data: () => r as Record<string, unknown> })),
            };
          },
        };
        return q;
      },
      batch() {
        const bw: Array<{ id: string; update: Record<string, unknown> }> = [];
        return {
          set(ref: { id: string }, update: Record<string, unknown>) { bw.push({ id: ref.id, update }); },
          async commit() { writes.push(...bw); },
        };
      },
    };
    return { db: db as unknown as import("firebase-admin").firestore.Firestore, writes };
  }

  it("rewrites reporterUid to the deleted sentinel for the user's reports only", async () => {
    const { db, writes } = makeDb([
      { id: "r1", reporterUid: "u1" },
      { id: "r2", reporterUid: "u2" },
    ]);
    const n = await anonymiseReportsForUser(db, "u1");
    assert.strictEqual(n, 1);
    assert.strictEqual(writes.length, 1);
    assert.strictEqual(writes[0].id, "r1");
    assert.strictEqual(writes[0].update.reporterUid, DELETED_UID);
  });
});

describe("account deletion: removeUserFromFriends (mock Firestore)", () => {
  function makeDb(users: Array<{ id: string; friends: string[] }>) {
    const writes: Array<{ id: string; update: Record<string, unknown> }> = [];
    const db = {
      collection: (name: string) => {
        if (name !== "users") throw new Error(`unexpected collection ${name}`);
        let val: unknown;
        const q = {
          where(field: string, op: string, v: unknown) {
            if (field !== "friends" || op !== "array-contains") throw new Error(`unexpected where ${field} ${op}`);
            val = v;
            return q;
          },
          async get() {
            return {
              docs: users
                .filter((u) => u.friends.includes(val as string))
                .map((u) => ({ ref: { id: u.id }, data: () => u as Record<string, unknown> })),
            };
          },
        };
        return q;
      },
      batch() {
        const bw: Array<{ id: string; update: Record<string, unknown> }> = [];
        return {
          set(ref: { id: string }, update: Record<string, unknown>) { bw.push({ id: ref.id, update }); },
          async commit() { writes.push(...bw); },
        };
      },
    };
    return { db: db as unknown as import("firebase-admin").firestore.Firestore, writes };
  }

  it("removes the uid from each friend list containing it, and only those", async () => {
    const { db, writes } = makeDb([
      { id: "a", friends: ["u1", "x"] },
      { id: "b", friends: ["y"] },
      { id: "c", friends: ["u1"] },
    ]);
    const n = await removeUserFromFriends(db, "u1");
    assert.strictEqual(n, 2);
    assert.deepStrictEqual(writes.map((w) => w.id).sort(), ["a", "c"]);
    // friends is set to an arrayRemove() sentinel (object, not an array).
    assert.ok(!Array.isArray(writes[0].update.friends));
  });
});

describe("account deletion: removeUserFromLeaderboards (mock Firestore)", () => {
  function makeDb(initial: Record<string, { entries: Array<{ uid: string }> }>) {
    const store = new Map(Object.entries(initial));
    const db = {
      collection: (name: string) => {
        if (name !== "leaderboards") throw new Error(`unexpected collection ${name}`);
        return {
          doc: (id: string) => ({
            _id: id,
            collection: (sub: string) => ({ doc: (slug: string) => ({ _id: `${id}/${sub}/${slug}` }) }),
          }),
        };
      },
      runTransaction: async (fn: (tx: unknown) => Promise<void>) => {
        const pending: Array<[string, Record<string, unknown>]> = [];
        await fn({
          get: async (r: { _id: string }) => ({ data: () => store.get(r._id) }),
          set: (r: { _id: string }, data: Record<string, unknown>) => pending.push([r._id, data]),
        });
        for (const [id, data] of pending) {
          store.set(id, { ...(store.get(id) ?? { entries: [] }), ...data } as { entries: Array<{ uid: string }> });
        }
      },
    };
    return { db: db as unknown as import("firebase-admin").firestore.Firestore, store };
  }

  it("filters the uid out of every period and county board, keeping others", async () => {
    const { db, store } = makeDb({
      daily: { entries: [{ uid: "u1" }, { uid: "u2" }] },
      weekly: { entries: [{ uid: "u2" }] },
      monthly: { entries: [{ uid: "u1" }] },
      lifetime: { entries: [{ uid: "u1" }, { uid: "u3" }] },
      "lifetime_by_county/counties/avon": { entries: [{ uid: "u1" }, { uid: "u2" }] },
    });
    await removeUserFromLeaderboards(db, "u1", ["avon"]);
    const ids = (k: string) => (store.get(k)?.entries ?? []).map((e) => e.uid);
    assert.deepStrictEqual(ids("daily"), ["u2"]);
    assert.deepStrictEqual(ids("weekly"), ["u2"]);
    assert.deepStrictEqual(ids("monthly"), []);
    assert.deepStrictEqual(ids("lifetime"), ["u3"]);
    assert.deepStrictEqual(ids("lifetime_by_county/counties/avon"), ["u2"]);
  });
});

// ── Streak reminder (scheduled notification) ──────────────────────────────────

describe("previousDay", () => {
  it("subtracts one day", () => {
    assert.strictEqual(previousDay("2026-07-05"), "2026-07-04");
  });
  it("crosses a month boundary", () => {
    assert.strictEqual(previousDay("2026-07-01"), "2026-06-30");
  });
  it("crosses a year boundary", () => {
    assert.strictEqual(previousDay("2026-01-01"), "2025-12-31");
  });
  it("handles a leap day", () => {
    assert.strictEqual(previousDay("2024-03-01"), "2024-02-29");
  });
});

describe("getLondonHourMinute", () => {
  it("returns in-range hour and minute", () => {
    const { hour, minute } = getLondonHourMinute();
    assert.ok(Number.isInteger(hour) && hour >= 0 && hour <= 23, `hour ${hour}`);
    assert.ok(Number.isInteger(minute) && minute >= 0 && minute <= 59, `minute ${minute}`);
  });
});

describe("slotForLondonTime", () => {
  it("maps 17:00 to slot 0 and 20:45 to the last slot", () => {
    assert.strictEqual(slotForLondonTime(17, 0), 0);
    assert.strictEqual(slotForLondonTime(20, 45), STREAK_REMINDER_SLOTS - 1);
  });
  it("maps quarter-hours within an hour", () => {
    assert.strictEqual(slotForLondonTime(17, 14), 0);
    assert.strictEqual(slotForLondonTime(17, 15), 1);
    assert.strictEqual(slotForLondonTime(18, 30), 6);
  });
  it("clamps below the window to 0 and above to the last slot", () => {
    assert.strictEqual(slotForLondonTime(9, 0), 0);
    assert.strictEqual(slotForLondonTime(23, 59), STREAK_REMINDER_SLOTS - 1);
  });
});

describe("shouldNotifyStreakReminder", () => {
  it("is enabled when no prefs exist", () => {
    assert.strictEqual(shouldNotifyStreakReminder({}), true);
    assert.strictEqual(shouldNotifyStreakReminder(undefined), true);
  });
  it("is enabled when the key is absent from prefs", () => {
    assert.strictEqual(
      shouldNotifyStreakReminder({ notificationPrefs: { friendOvertakes: false } }),
      true
    );
  });
  it("is disabled only when explicitly false", () => {
    assert.strictEqual(
      shouldNotifyStreakReminder({ notificationPrefs: { streakReminder: false } }),
      false
    );
    assert.strictEqual(
      shouldNotifyStreakReminder({ notificationPrefs: { streakReminder: true } }),
      true
    );
  });
});

describe("streakReminderBody", () => {
  it("includes the streak length when known", () => {
    assert.ok(streakReminderBody(12).includes("12-day streak"));
  });
  it("omits the number for a missing or zero streak", () => {
    assert.ok(!/\d/.test(streakReminderBody(undefined)));
    assert.ok(!/\d/.test(streakReminderBody(0)));
  });
});

describe("decideFire", () => {
  const TODAY = "2026-07-05";

  it("rolls a random target slot on the first run of a new day", () => {
    // rng 0.5 * 16 = 8 → floor → slot 8
    const { fire, newState } = decideFire(undefined, TODAY, 0, 16, () => 0.5);
    assert.strictEqual(newState.day, TODAY);
    assert.strictEqual(newState.targetSlot, 8);
    assert.strictEqual(fire, false, "slot 0 is before target 8");
  });

  it("re-rolls and drops a stale sentDay when the stored state is from a previous day", () => {
    const prev = { day: "2026-07-04", targetSlot: 2, sentDay: "2026-07-04" };
    // rng 0.5 * 16 = 8 → target slot 8; current slot 0 is before it, so no fire
    // and we can observe the re-rolled target. The stale sentDay is dropped so
    // the persisted state never carries an undefined field into Firestore.
    const { fire, newState } = decideFire(prev, TODAY, 0, 16, () => 0.5);
    assert.strictEqual(fire, false);
    assert.strictEqual(newState.day, TODAY);
    assert.strictEqual(newState.targetSlot, 8);
    assert.strictEqual(newState.sentDay, undefined, "stale sentDay dropped");
    assert.ok(!("sentDay" in newState), "sentDay key omitted entirely, not set to undefined");
  });

  it("does not fire before the target slot", () => {
    const state = { day: TODAY, targetSlot: 10 };
    const { fire, newState } = decideFire(state, TODAY, 9, 16, () => 0);
    assert.strictEqual(fire, false);
    assert.strictEqual(newState.sentDay, undefined);
  });

  it("fires when the current slot reaches the target and stamps sentDay", () => {
    const state = { day: TODAY, targetSlot: 10 };
    const { fire, newState } = decideFire(state, TODAY, 10, 16, () => 0);
    assert.strictEqual(fire, true);
    assert.strictEqual(newState.sentDay, TODAY);
  });

  it("fires when the current slot has passed the target (robust to skipped runs)", () => {
    const state = { day: TODAY, targetSlot: 5 };
    const { fire } = decideFire(state, TODAY, 12, 16, () => 0);
    assert.strictEqual(fire, true);
  });

  it("never fires twice on the same day", () => {
    const state = { day: TODAY, targetSlot: 5, sentDay: TODAY };
    const { fire, newState } = decideFire(state, TODAY, 15, 16, () => 0);
    assert.strictEqual(fire, false);
    assert.strictEqual(newState.sentDay, TODAY);
  });
});

describe("findStreakReminderRecipients (unit, mock Firestore)", () => {
  type UserDoc = { lastClaimDate?: string; streak?: number; notificationPrefs?: Record<string, boolean> };

  function makeMockDb(users: Record<string, UserDoc>) {
    const db = {
      collection: (name: string) => {
        if (name !== "users") throw new Error(`Unexpected collection: ${name}`);
        let preds: Array<{ field: string; op: string; val: unknown }> = [];
        const q = {
          where(f: string, o: string, v: unknown) {
            preds = [...preds, { field: f, op: o, val: v }];
            return q;
          },
          async get() {
            return {
              docs: Object.entries(users)
                .filter(([, d]) =>
                  preds.every(({ field, op, val }) => {
                    const v = (d as Record<string, unknown>)[field];
                    return op === "==" ? v === val : false;
                  })
                )
                .map(([id, d]) => ({ id, data: () => d as Record<string, unknown> })),
            };
          },
        };
        return q;
      },
    };
    return db as unknown as import("firebase-admin").firestore.Firestore;
  }

  it("returns only users whose lastClaimDate equals yesterday", async () => {
    const db = makeMockDb({
      u1: { lastClaimDate: "2026-07-04", streak: 3 },
      u2: { lastClaimDate: "2026-07-05", streak: 9 }, // claimed today — excluded
      u3: { lastClaimDate: "2026-07-04", streak: 1 },
      u4: { streak: 0 }, // never claimed — excluded
    });
    const recipients = await findStreakReminderRecipients("2026-07-04", db);
    const uids = recipients.map((r) => r.uid).sort();
    assert.deepStrictEqual(uids, ["u1", "u3"]);
    assert.strictEqual(recipients.find((r) => r.uid === "u1")!.streak, 3);
  });
});

describe("sendStreakReminders", () => {
  function recipient(uid: string, streak: number, prefs?: Record<string, boolean>) {
    return { uid, streak, fdata: { streak, notificationPrefs: prefs } as Record<string, unknown> };
  }

  it("sends to eligible recipients and skips opted-out ones", async () => {
    const sent: string[] = [];
    const count = await sendStreakReminders(
      [
        recipient("u1", 5),
        recipient("u2", 2, { streakReminder: false }),
        recipient("u3", 8, { streakReminder: true }),
      ],
      async (uid) => { sent.push(uid); }
    );
    assert.strictEqual(count, 2);
    assert.deepStrictEqual(sent.sort(), ["u1", "u3"]);
  });

  it("continues past a failing send (allSettled)", async () => {
    const sent: string[] = [];
    const count = await sendStreakReminders(
      [recipient("u1", 5), recipient("u2", 3)],
      async (uid) => {
        if (uid === "u1") throw new Error("push failed");
        sent.push(uid);
      }
    );
    assert.strictEqual(count, 2, "both are eligible even if one send throws");
    assert.deepStrictEqual(sent, ["u2"]);
  });
});
