# Postbox Game — Roadmap

Working backlog, organised by app release. Current shipped version is
`pubspec.yaml`'s `1.2.0+13`. Each release names a **theme** and a **ship gate**;
items inside it can be re-ordered freely.

This file replaces the bulk-created draft PRs `#94`–`#112` (closed once this
lands). Their original bodies are preserved below for diff archaeology.

## Status legend

- **In flight** — has an open PR or active branch.
- **Queued** — scoped, not started.
- **Deferred** — useful, not yet scheduled.
- **Speculative** — keep as a sketch; revisit if a clear need appears.
- **Done** — shipped; links to the merged PR.

## Release index

| Version | Theme | Status |
|---|---|---|
| **v1.2** | Intro polish | Done |
| **v1.3** | Platform foundations (EU region + observability) | Done |
| **v1.4** | Trust & safety (GDPR, anti-cheat) | In flight |
| **v1.5** | Resilience & offline play | Queued |
| **v1.6** | Engagement & avatars (social loops + Postie avatar) | Deferred |
| **v1.7** | Collection & content | Deferred |
| **v1.8** | Reach (iOS, localisation) | Deferred |
| **v2.0** | Growth (Analytics + experimentation) | Deferred |
| **Backlog** | Speculative big-rocks | Speculative |

---

## v1.2 — Intro polish  (Done)

**Theme**: the small visible UX win that's already on a branch.
**Ship gate**: `flutter analyze` + tests green, intro effects wired into `lib/intro.dart`. ✅ met.

- **Tier 1 intro polish — `flutter_animate`** — ✅ shipped. The `flutter_animate`
  dependency and the three ship-gate effects (postbox `fadeIn` + elasticOut
  `scale`, James `slideX` with `easeOutBack`, Mega Points `shimmer` + confetti)
  landed in `7ea9820`, which **superseded PR #82** (closed, not merged — its
  branch had drifted off master).
- **Entrance-animation follow-up** — ✅ shipped. Extended `flutter_animate`
  entrances to the remaining steps that previously popped in: step-0 title/
  subtitle, the dialogue cards (steps 2–3), the staggered "How it works"
  overview (step 5), and the outro (step 6). Added `test/intro_test.dart`
  smoke test (steps 0→6, `pump`-paced to avoid the infinite-shimmer hang).
  Version bumped to `1.2.0+13`.

> **Postie avatar (PR #113)** was bundled here originally but has been
> moved down to **v1.6** after Trust & safety and Resilience. PR #113 is
> non-draft and ready, but will sit waiting through v1.3–v1.5. **Risk**: long-lived
> branch accumulates merge conflicts (especially against `leaderboard_screen.dart`, `friends_screen.dart`, `user_profile_page.dart`,
> `startScoring.ts`, `_leaderboardUtils.ts`). Mitigation: rebase #113
> onto `master` whenever any of those files changes.

---

## v1.3 — Platform foundations  (Done)

**Theme**: reduce UK latency and stand up the observability needed to spot regressions, so v1.4's harder changes ship safely.
**Ship gate**: UK round-trip on `nearbyPostboxes` < 150 ms p50; Crashlytics dashboard shows the new custom keys; Performance traces visible for the 6 trace names below.

> **Status**: shipped — merged to `master` as `1.3.2+16`. The region migration is
> deployed (`eur3`); the two observability items below (Performance traces;
> Crashlytics custom keys + non-fatals) are implemented and building green (live-
> dashboard confirmation pending a production release). The Android Gradle 8.14 /
> AGP 8.11.1 bump shipped alongside; Flutter Built-in Kotlin is not yet viable here
> (its bundled Kotlin 2.0.0 can't read our deps' 2.2.0 metadata), so the "app
> applies KGP" deprecation warning remains by design. The Remote Config game-balance
> item moved to **v1.4**.

### Migrate Firebase services us-central1 → europe-west2  (was #112-adjacent / new plan)

The app serves UK users exclusively but every Firebase service is US-hosted.
Each callable makes several Firestore reads from `us-central1`, so a UK
round-trip is ~250–400 ms today. Target: ~50–120 ms.

**Critical caveat**: moving only Functions while Firestore stays in `nam5`
will *worsen* end-to-end latency. Functions and Firestore must move together.

| Service | From | To |
|---|---|---|
| Cloud Functions (all 8) | us-central1 | europe-west2 |
| Firestore `(default)` database | nam5 | eur3 |
| Default Storage bucket | US | europe-west2 |
| Auth / FCM / App Check / Analytics | n/a (global) | unchanged |

**Migration order (sequence is load-bearing)**

1. **Pre-flight**: a managed export/import bucket must be **co-located with the database**, and you change locations mid-migration, so you need **two** buckets. Create a **US** bucket for exporting out of `nam5` (`gcloud storage buckets create gs://the-postbox-game-backup-us --location=us`) and an **EU** bucket for importing into `eur3` (`gcloud storage buckets create gs://the-postbox-game-backup-eu --location=europe-west2`). Pre-migration backup → US bucket: `gcloud firestore export gs://the-postbox-game-backup-us/pre-migration-$(date +%F)`. Tag the repo, freeze deploys.
2. **Region-pin Cloud Functions** (code change, no deploy yet):
   - v2 callables (`nearbyPostboxes`, `startScoring`, `updateDisplayName`, `registerFcmToken`, `userClaimHistory`, `submitReport`, `reviewReport`, `routePostboxes`): add `{ region: "europe-west2" }` to `onCall` options.
   - v2 scheduler (`newDayScoreboard`): add `region: "europe-west2"` alongside `schedule` + `timeZone`.
   - v1 triggers (`onFriendAdded`, `onUserCreated`): wrap with `functionsV1.region("europe-west2")`.
3. **Firestore database move (disruptive — Path A recommended)**:
   1. Maintenance mode via the existing `maintenance_mode` Remote Config flag (per `b721caa`); client renders "we'll be right back".
   2. Final export → **US** bucket: `gcloud firestore export gs://the-postbox-game-backup-us/final-$(date +%F-%H%M)`; note the printed `outputUriPrefix`.
   3. Baseline counts on the frozen `nam5` data: `cd functions && npm run verify-migration -- snapshot --out pre-nam5.json`.
   4. Copy the final export US→EU (eur3 can only import from an EU bucket): `gcloud storage cp -r gs://the-postbox-game-backup-us/final-… gs://the-postbox-game-backup-eu/final-…`.
   5. Delete `(default)` (delete protection is already `DISABLED`).
   6. `gcloud firestore databases create --location=eur3 --database='(default)'`.
   7. Re-deploy `firestore.rules` and `firestore.indexes.json`; wait for the 5 composite indexes to finish (`gcloud firestore indexes composite list`) before reopening traffic.
   8. `gcloud firestore import gs://the-postbox-game-backup-eu/final-…` (from the **EU** bucket).
   9. Verify counts match: `npm run verify-migration -- snapshot --out post-eur3.json && npm run verify-migration -- compare pre-nam5.json post-eur3.json` (exit 0 = safe). Covers `postbox`, `claims`, `users`, `leaderboards`, `fcmTokens`, `reports`, `reportQuotas` + nested groups.
   - Path B (named DB in `eur3`, dual-write, switch reads, retire `(default)`) is the fallback if Path A downtime is unacceptable; **avoid** unless forced, since every `admin.firestore()` call would need to target the non-default DB.
4. **Deploy new functions**: `firebase deploy --only functions` *creates* europe-west2 copies; **decline** the prompt to delete the orphaned us-central1 copies — keep the 8 callables live for old installs. But the 3 event-driven functions (`onUserCreated`, `onFriendAdded`, `newDayScoreboard`) fire automatically and would double-run from both regions, so delete only those old copies: `firebase functions:delete onUserCreated onFriendAdded newDayScoreboard --region us-central1`. Verify all **11** healthy in `europe-west2` and that no us-central1 `newDayScoreboard` scheduler job remains.
5. **Pin Flutter client** to europe-west2 via a single helper `lib/firebase_functions_eu.dart` exposing an `appFunctions` getter (`instanceFor(region: 'europe-west2')`). Done in PR #159: all 11 call sites swapped (`nearby`, `claim_quiz_sheet`, `wear` ×2, `route` ×2, `reports`, `admin`, `user_repository`, `claim_history_screen`, `notification_service`), guarded by `test/firebase_functions_region_test.dart`. Bump the app version. Keep both regions live until us-central1 invocations drop to zero in Cloud Logging.
6. **Storage bucket** (do last): create `the-postbox-game-eu` in `europe-west2`, regen SDK config via FlutterFire CLI, migrate the existing objects with `gsutil -m cp -r` (the default bucket holds `report_photos/` and `osm_changesets/`).
7. **Decommission us-central1 functions** once Cloud Logging shows zero invocations for one release cycle: `firebase functions:delete <name> --region us-central1` for each.

**Risks & mitigations**

- Export/import data loss → two backups (pre + final); keep `(default)` in `nam5` until import is verified.
- Index rebuild lag in `eur3` → wait for indexes before re-enabling traffic.
- Old app installs hitting us-central1 → keep us-central1 functions live for one release cycle; force-upgrade nag below a min version.
- `onFriendAdded` v1 trigger is tied to the database location — verify friend-add notifications still fire after the move.
- Cloud Scheduler double-firing → confirm us-central1 `newDayScoreboard` job is deleted to avoid double scoreboard rollover.

**Verification**

- **Latency**: from a UK device, time `nearbyPostboxes` round-trip before vs after — expect ~250–400 ms → ~50–120 ms. Land Performance traces (next item) **first** so this is measurable.
- **Functional smoke test**: sign-up (`onUserCreated`), claim (`startScoring` + leaderboard updates), add a friend (`onFriendAdded`), manually invoke `newDayScoreboard` to confirm rollover.
- **Tests**: `cd functions && npm test` + `flutter test` both green.
- **Logs**: Cloud Logging shows invocations only in `europe-west2` after the deprecation window.

**Rollback**: delete the new `(default)`, re-create in `nam5`, import the pre-migration backup **from the US bucket** (`gs://the-postbox-game-backup-us/pre-migration-…`), re-deploy us-central1 functions from the freeze tag, leave the Flutter client unshipped (or revert the `instanceFor` change), ship a hotfix.

### Performance Monitoring custom traces  (was #105)

Performance SDK is already pulled in. Land **before** the region migration so the latency win is measurable.

| Trace | Attributes | Scope |
|------|------------|-------|
| `callable.nearbyPostboxes` | `resultsCount`, `radius` | `lib/nearby.dart` |
| `callable.startScoring` | `monarch`, `outcome` | `lib/claim.dart` |
| `map.tileLoad` | `zoom` | `lib/widgets/postbox_map.dart` |
| `friends.load` | `count` | `lib/friends_screen.dart` |
| `leaderboard.render` | `period`, `rowCount` | `lib/leaderboard_screen.dart` |
| `intro.onboarding` | `variant` | `lib/intro.dart` |

- Helper `lib/services/perf_service.dart` with `traceAsync<T>(name, attrs, fn)`.
- Trace-name constants in a single file to prevent typo fragmentation.
- Keep total trace count below 100 for free tier.
- Alerts: p95 latency regression > 50 % on `callable.startScoring`.

### Crashlytics custom keys + non-fatal logging  (was #98)

Crashlytics is already configured. Add structured context and promote handled
exceptions in key flows to non-fatals.

- Custom keys: `auth_state` (`anon|email|google`), `active_tab`, `last_claim_id`, `last_monarch`, `remote_config_fetch_ts`, `has_location_permission`.
- Non-fatals on: `UserRepository.signIn*` catches, `nearbyPostboxes` / `startScoring` callable failures, `FlutterCompass` stream errors, leaderboard snapshot errors, App Check token fetch failures.
- Helper `lib/services/crashlytics_helper.dart` with `setContext` (length-guarded) and `recordHandled(error, stack, { reason })` (always `fatal: false`).
- Centralise tab changes in `home.dart` to set `active_tab` once.
- Route all callable wrappers through a helper that logs on failure and rethrows.
- Privacy: never log emails, display names, or exact coordinates as custom keys.
- Rate-limit noisy non-fatals (drop after first per session for expected network flakes).

---

## v1.4 — Trust & safety  (Queued)

**Theme**: harden the platform now that we can see what's happening (v1.3 observability).
**Ship gate**: account-deletion flow tested end-to-end in staging; impossible-travel detector in shadow mode logging flags but not blocking; Remote Config drives `claim_radius_meters` and `points_by_monarch` end-to-end (client + Cloud Functions) with the safety bounds enforced.

> **App Check enforcement is now split.** Server-side `enforceAppCheck` on the
> claim callables is a hard *prerequisite* for v1.5's offline work (which starts
> accepting client-supplied timestamps), so the Android half moves **up** into
> **v1.5**. The iOS `AppleProvider` wiring stays in **v1.8** alongside the iOS
> build, since that's what actually gates it. See both items.

### Remote Config for game balance and copy  (was #107, moved from v1.3)

The Remote Config *infrastructure* (typed `RemoteConfigService`, fetch lifecycle,
push updates, kill switches, `maintenance_mode`) already shipped in v1.3. What
remains is the game-balance tuning layer: centralise tunable values so balance,
reminder copy, and James cadence change without a client release. Both client
and Cloud Functions read Remote Config.

- Initial params: `claim_radius_meters` (30), `points_by_monarch` (JSON), `james_idle_min/max_seconds`, `daily_reminder_hour_local`, `nearby_radius_meters`, `quiz_required_streak`.
- Client: extend `lib/remote_config_service.dart` with typed getters for the params above (fetch-and-activate is already wired at app start, min 1 h prod / 0 debug); add a force-refetch on login.
- Backend: new `_config.ts` admin fetch with 5 min in-memory cache; `_getPoints.ts` honours a `points_by_monarch` override with the hard-coded fallback; `startScoring` reads `claim_radius_meters`.
- Already shipped (v1.3 and earlier): the `RemoteConfigService` wrapper + admin debug screen, `b721caa` (`maintenance_mode`/`message` template), `1caca74` (Analytics user properties for audience targeting).
- Rollout: ship client first with defaults equal to current code, then backend, then tune via console.
- Risk: stale client cache hides a bad value — force refetch on login. Cost drift if `points_by_monarch` mis-set — sanity-check rejecting values outside `[1, 50]`.

### GDPR "Delete User Data" Firebase Extension  (was #99)

Install the official extension. Configure paths:

- Firestore: `users/{UID}`, `fcmTokens/{UID}`, `recaps/{UID}/periods/{DOC}`.
- Storage: `claims-photos/{UID}/`, `report_photos/{UID}/`.
- RTDB (if presence ships later): `/status/{UID}`.
- **Claims must not be hard-deleted** — anonymise via an `onUserDeleted` Auth trigger that rewrites the user's claims to `{ uid: "deleted", displayName: "Deleted user" }` before the extension fan-out, to preserve leaderboard integrity.

In-app:

- "Delete my account" button in Settings with confirmation + re-auth (Firebase requires recent sign-in for `User.delete()`).
- Call `FirebaseAuth.instance.currentUser!.delete()` — extension + function fan-out does the rest.
- Audit trail: keep the extension's default log; add `deletions/{YYYY-MM-DD}` doc with counts for internal visibility.

Test in staging first: create a user with claims, photos, friends; delete; assert no residuals.

### Abuse detection (impossible-travel and claim anomalies)  (was #112)

`startScoring` already has a travel-speed anti-spoof check. Extend to:

- **Impossible travel**: two claims < N minutes apart separated by distance requiring > 200 km/h (start with 180 km/h / 50 m/s).
- **Repeated device ID hash on different accounts**: same hash claims across ≥ 3 accounts in 24 h.
- **Clustered claims in identical coordinates**: same lat/lng to 6 dp repeated across sessions.
- **Out-of-window claims**: location server-timestamp delta vs. client timestamp > 2 min.

Data:

- `claims/{id}` gains `deviceIdHash`, `clientTsMs`, `travelSpeed`.
- `moderation/flags/{flagId}` = `{ uid, reason, severity, claimId?, createdAt, reviewed, action? }`.
- `users/{uid}.trustScore` (server-only) decays with flags, recovers with time.

Implementation:

- Firestore trigger `onClaimCreated` (or inline in `startScoring`) computes signals against the user's previous claim — haversine for distance, `(now - prevTs)` for speed.
- Writes a flag doc on threshold breach + Crashlytics non-fatal for internal visibility.
- Phase 2: when `trustScore < threshold`, require step-up verification (reCAPTCHA via App Check).

Admin UI: mirror `lib/admin/admin_reports_screen.dart` as `lib/admin/admin_abuse_screen.dart`; existing rollback path in `_recomputeScores.ts` handles voiding claims.

Shadow mode first — log flags, no user-facing effect — for 2 weeks; tune thresholds from Firestore exports. False-positive guard: require **two** signals (e.g. impossible travel AND repeated device hash) before any action.

---

## v1.5 — Resilience & offline play  (Queued)

**Theme**: the claim loop is a chain of live callable round-trips, and players hunt
postboxes on foot — lanes, parks, villages — which is exactly where reception fails.
Today there is no offline story at all: no connectivity detection (the app infers
"offline" from `FirebaseFunctionsException.code == 'unavailable'` at three call
sites), no timeouts, no retries, no local cache. Make the flow degrade gracefully on
a bad link, then work outright without one.

**Ship gate**: a claim whose response is dropped mid-flight is never lost (the player
sees their points, not an empty state); `startScoring` and `nearbyPostboxes` enforce
App Check with a denial rate < 1 %; a claim captured with no signal settles correctly
on reconnect, including across a London-midnight rollover, without disturbing any
other player's leaderboard.

> Full design (with the attack analysis and the file-level trace) lives in the plan
> that produced this entry. Detail below is deliberately flat, per this doc's rules.

### Why this is more than a nice-to-have

Two concrete failures exist today:

1. **A player can lose a claim they earned.** The claim *write* is idempotent
   (deterministic doc ID `claims/{uid}_{box}_{day}`), but the *response* is not. If
   the response is dropped, the retry hits the "already claimed today" fast-path in
   `startScoring` and the client renders an empty state — no points, no confetti. The
   claim landed; the player never sees it.
2. **A player in a notspot cannot play at all.** Every step needs signal.

Three findings from tracing the flow shape the whole design:

- **The quiz is 100 % client-side.** `startScoring` accepts only `{lat, lng, clientTsMs}`
  and never sees the answer — `quiz_helpers.dart` builds the options from the `monarch`
  values `nearbyPostboxes` already returned, and `claim_quiz_sheet.dart` grades locally.
  The quiz is flavour, not an authorisation gate, so it is no obstacle to offline play.
- **`startScoring` derives *which* boxes you claimed from position alone** — it runs
  `lookupPostboxes(lat, lng, 30)` and claims every unclaimed box in range. So a claim
  can be represented as *"I stood here, then"* and adjudicated later exactly as it
  would have been live.
- **The travel-speed check would reject a flushed queue.** `enforceTravelSpeedLimit`
  compares `Date.now()` against the previous claim's *server* timestamp, and
  `_travelSpeed.ts` floors elapsed time at 1 second. Flushing sequentially computes
  `speed = 60 × distance`, so any two queued boxes more than ~32 m apart hard-reject
  the second. This must be fixed before anything can be flushed.

### The security problem, and the design that answers it

Today's travel-speed check is not really an anti-spoof control — the server has always
trusted client-supplied lat/lng, so a GPS spoofer already wins. What it actually is, is
a **serialisation tax**: farming 300 boxes across a city forces a script to space its
calls out in real wall-clock time.

A naive offline claim deletes that tax. Because the claim ID is `{uid}_{box}_{day}`, an
attacker can save the outbox JSON, add 86,400,000 ms to every capture time, and
resubmit tomorrow — same boxes, full points, from an armchair, forever. The travel-speed
chain validates perfectly, because a uniformly-shifted trace has identical implied speeds.

**The fix is a server-issued offline capture token.** On any successful online call the
server issues an HMAC-signed token `{uid, issuedAtMs, exp, budget, nonce}` (secret in
Secret Manager). Every offline capture carries it, and at flush the server enforces
`capturedAtMs >= token.issuedAtMs`, `capturedAtMs <= serverNow`, and single-use nonce
consumption against `budget`. Both bounds are server-attested, so the whole offline
timeline must fit inside a wall-clock window the server actually observed — you cannot
submit an 8-hour synthesised walk five minutes after going offline. That restores the
serialisation tax, which is the property that matters.

Chaining capture times is a *consistency* control, not a security control. The token is
what does the work.

### Prerequisites (both nearly free)

- **`enforceAppCheck: true` on `startScoring` and `nearbyPostboxes`.** App Check is
  activated client-side but **no callable enforces it** — `enforceAppCheck` appears
  nowhere in `functions/src`. One options object per function on `firebase-functions` v2.
  Highest-leverage anti-abuse control available, and it matters far more once an endpoint
  accepts client-supplied timestamps. (iOS `AppleProvider` wiring stays in v1.8.)
- **`allow read: if false` on `/postbox`.** `firestore.rules` currently lets any signed-in
  user read every postbox `geopoint`, and **no Dart or Kotlin code reads that collection**
  — everything goes through the callables. So the fuzzy compass is presently a UI
  convention, not a security property. Closing the rule costs nothing and makes the
  on-device cache below a deliberate, bounded exposure rather than a formality.

### Phase 1 — Survive a flaky link

Ships alone and fixes the lost-claim bug. The common real failure is *"one bar, request
hangs, I lose my quiz sheet and have to walk back and rescan"* — not "no signal all walk".
Most of the user value is here.

- **`attempts/{attemptId}` idempotency doc** — `{uid, status, result, expiresAt}`.
  Transaction at the top of the handler: `done` → return the stored result verbatim;
  `in_progress` → throw `aborted`; else create. One doc read by ID, no index. Beats a
  `claims`-query approach, which would double-credit across a midnight boundary and
  cannot represent a *zero-claim* attempt (`found: false` / `allClaimedToday` write no
  claim doc — exactly the responses worth replaying). Firestore native TTL on `expiresAt`.
- **Callable timeouts + jittered retry** on `unavailable` / `deadline-exceeded`, added at
  the `appFunctions` chokepoint (`lib/firebase_functions_eu.dart`). **Must land after the
  attempts doc** — a shorter timeout *increases* the rate of "the server may or may not
  have processed this", so retry without idempotency is retrying a non-idempotent write
  against an uncertain outcome.
- **Stop destroying sheet state.** `claim_quiz_sheet.dart` calls `_cancel()` on every
  network failure, tearing the sheet down; the claim path strands the user mid-quiz behind
  a SnackBar. Add a `networkError` stage with a Retry that preserves the scan + quiz state.
- **`Geolocator.getLastKnownPosition()` fallback** when the 30 s fix times out — currently
  never used anywhere in the app.
- **Connectivity service** (`connectivity_plus`) exposing a `ValueListenable<bool>`; an
  `OfflineBanner` cloned from `maintenance_banner.dart` and mounted beside it in `home.dart`.
  More Postman James offline lines — there is currently exactly one (`errorOffline`).
- **Cached reads** — Firestore persistence is *already on by default* on Android/iOS, so the
  work is `Source.cache` fallbacks and `isFromCache` staleness chips on History /
  Leaderboard / Friends, not "enabling persistence".

### Phase 2 — A backend that can accept a claim made in the past

Server-only; nothing user-visible ships here.

- **Extract `_claimCore.ts`** — the scoring write path lifted out of `startScoring`, which
  becomes a thin live wrapper. Single source of truth, in the spirit of `_routePlanner.ts`.
- **Add `eventTime`; don't redefine `timestamp`.** `timestamp` stays the immutable
  server-write time (audit trail; `abuse.ts` reads it). `eventTime` is when the user was
  physically there. Travel-speed orders by `eventTime`.
  ⚠️ **Deploy hazard**: Firestore *excludes documents missing the `orderBy` field*. Every
  existing claim lacks `eventTime`, so the neighbour query returns empty for every user and
  `enforceTravelSpeedLimit` **silently no-ops for the entire user base** until each user's
  first post-deploy claim. A backfill (`eventTime = timestamp`, reusing the
  `WRITE_BATCH_SIZE = 400` pattern in `_recomputeScores.ts`) must land **before** the query
  switches over.
- **Two-sided neighbour travel-speed check.** A claim at time `t` must be plausible against
  both the nearest stored claim *before* `t` and the nearest *after* it. One-sided ("reject
  anything older than your newest claim") permanently strands a legitimate claim: capture
  t1 and t2 offline → flush t1 → network dies → make a live claim at T → retry t2 where
  t2 < T → rejected forever. Two-sided *inserts* into the timeline instead, and catches
  backdating a capture to just before a known-distant live claim.
  - **Process batch items sequentially, not `Promise.allSettled`** — earlier items must be
    visible to later items' neighbour queries. The `allSettled` reflex in `startScoring` is
    the trap; used across items, the chain isn't validated at all.
  - Don't change `checkTravelSpeed`'s signature — a substantial pinned suite depends on it.
  - The 1 s floor becomes dangerous with client times (an NTP resync mid-outbox yields a
    zero delta, and a 40 m gap reads as 2400 m/min — spuriously rejecting an honest user).
    Reject non-monotonic sequences server-side, **and** derive `capturedAtMs` client-side
    from a monotonic anchor (`Stopwatch` elapsed + wall clock at flush).
- **Offline capture token** — issue on `nearbyPostboxes` / app start, verify at flush.
- **Fix the uniqueness query.** It currently asks for claims with `dailyDate < today`, which
  for a backdated claim misses a *later* claim on the same box and **double-counts a unique
  postbox**. Replace with a `.count()` on `(userid, postboxes)`; the existing 3-field index
  covers the prefix.
- **`lookupPostboxes` needs a `today?` parameter** — it calls `getTodayLondon()` internally
  and derives `claimedToday` from it, so adjudicating a backdated claim computes the
  response against the wrong day.
- **`streakFromClaimDays(days, today)`** — a new pure helper. `computeNewStreak` is
  forward-only and cannot handle out-of-order days: a live claim on Wed landing *before* a
  Tue-dated flush resets the streak to 1, with no forward-only repair. Flush path only; the
  live path keeps the cheap incremental version. This is what turns a late flush into a
  **saved streak** — the moment that makes the feature feel good.
- **`flushOfflineClaims` callable**, sharing `_claimCore`. Must **re-check maintenance mode
  server-side** — `MaintenanceGuard` is client-only, so an offline user can queue during
  maintenance and flush into a mid-migration server.
- **New shadow abuse signals**: `queuedForMs`, `batchSize` / `batchSpanMs`, and **speed
  variance across the batch** (a synthesised trace has near-constant implied speed; a human
  doing a postbox round stops, waits, gets a coffee). Derive the `offline` flag server-side
  from which handler ran — never from client payload, or it becomes a self-declared
  exemption from a security signal. Don't exempt offline claims from `outOfWindowSignal`;
  re-point it at a `flushClientTsMs` so it still catches a tampered device clock, which is
  precisely the attack this phase opens.
- **Remote Config**: `kill_switch_offline_claims`, `offline_claim_grace_hours` (~36),
  `max_offline_claims_per_day`. Pairs with the v1.4 game-balance Remote Config work.

**Backdating needs no per-day leaderboard archive.** With `updateUserLeaderboards` still
called with the **real** today, its weekly/monthly range queries pick up a backdated claim
automatically while its exact `dailyDate == today` daily query correctly excludes it; and
`maxDailyFromClaims` already buckets by `dailyDate`. Claims, lifetime, county, weekly,
monthly, `maxDailyPoints`, unique count and streak all get credited. Only a *closed* daily
board doesn't — and no UI can display one.

⚠️ **The landmine**: never pass a backdated `today` to `updateUserLeaderboards`. It would
see a `periodKey` mismatch, set `existing = []`, and `tx.set(..., { merge: false })` —
**wiping the daily leaderboard for every player**, stamped with yesterday's key. Silent
cross-user data loss. Deserves a dedicated test.

### Phase 3 — Offline claiming, warm path

The high-value, low-risk half.

- Cache the last `nearbyPostboxes` payload — it contains **no coordinates** (`applyUserClaims`
  strips them), so this leaks nothing — alongside a server-issued, position-bound,
  short-lived `scanId`. An offline claim requires `scanId` + freshness + proximity to the
  scan position.
- **`scanId` *is* the offline capture token, for free** — the server has already told this
  user a box is here, so the abuse delta is small.
- Full quiz preserved: same options, same grading, same feel. This is the "signal died
  mid-claim" rescue, and it is the case that actually happens.
- `claim_outbox.dart` (queue as JSON in `shared_preferences`) + `outbox_sync.dart` (flush on
  connectivity-restored / app-resume / manual "Send now", reconciling results honestly into
  the UI and James).

### Phase 4 — Blind capture and offline discovery  (Conditional — do not start by default)

**Explicitly gated on evidence.** This phase carries most of the attack surface and the
least payoff: no quiz, no feedback at the box, and it is what forces postbox coordinates
onto the device. **Ship Phases 1–3, measure, and only build this if the warm path
demonstrably fails to cover real usage.** If Phases 1–3 land well, the right outcome may be
to drop it and move the pieces to Backlog.

If it does go ahead, it ships behind `kill_switch_offline_claims`, with a low daily cap and
gated on `trustScores`:

- **Blind capture ("post it later")** — the player stands at a box and taps; the app banks
  `{position, capturedAtMs, token}`. The server adjudicates on flush and reports back.
  Requires zero postbox data on device.
- **Offline discovery** — a `prefetchArea` callable (bounded radius, hard cap on boxes,
  rate-limited via the transactional-counter pattern in `reports.ts`), an app-private
  `postbox_cache.dart`, and a `local_scan.dart` mirroring `lookupPostboxes` on-device
  (geohash cell + neighbours, distance filter, 16-wind compass) against `_geo.ts`'s
  `setPrecision`. Dart's `latlong2` won't agree with `geolib` to the metre, so keep the
  local radius slightly permissive (~35 m) and let the server remain the judge on flush.
- **Product guardrail**: the offline UI stays the fuzzy compass and scan. The cache is an
  implementation detail reproducing the existing experience offline; it must never become a
  map-of-all-pins surface. That — not the rules file — is what preserves the game.

### Deliberately cut

- **A pre-midnight "you have unposted claims" notification.** It fires precisely when the
  user has no signal and therefore cannot act, converting a silent loss into an announced,
  unavoidable one. Strictly worse than saying nothing.
- **A per-day leaderboard archive.** Unnecessary — see the backdating note above.

### Drive-by bug found while tracing the claim path  (fix in this release)

`android/app/src/auto/kotlin/com/code418/postbox_game/car/ClaimAction.kt` calls
`FirebaseFunctions.getInstance()` with **no region**, so it targets `us-central1` while
every function deploys to `europe-west2` (`_region.ts`). The CI guard
`test/firebase_functions_region_test.dart` only scans `lib/`, so Kotlin call sites are
invisible to it — **the Android Auto claim button may simply not work**. Confirm against
the live deployment, pin the region, and extend the guard test to cover Kotlin sources.

### Known test breakage (decide deliberately, don't discover in CI)

- `test/cross_language_sync_test.dart` reads `functions/src/startScoring.ts` and regexes
  `CLAIM_RADIUS_METERS`. Moving that constant into `_claimCore.ts` fails the anchor
  assertion hard — and a re-export doesn't match the regex either. Keep the literal
  declaration in `startScoring.ts`, or update the test's path.
- `test.index.ts` imports `dailyClaimPatch` from the `startScoring` module, and pins
  `checkTravelSpeed`'s signature.
- Extend the `updateUserLeaderboards` mock-Firestore suite with the "a backdated `today`
  must not clobber the daily board" case — highest-value new test in the project.

---

## v1.6 — Engagement & avatars  (Deferred)

**Theme**: build the daily-return loop and the friend-pressure loop on top of the now-stable v1.4 platform — and ship the visible-identity work (Postie avatars) so users have something to flex with on the new live leaderboards.
**Ship gate**: DAU / WAU lift measurable in Analytics; POTD claim rate ≥ 30 % of DAU; weekly recap engaged-with by ≥ 25 % of recipients; avatar coverage > 50 % of WAU within two weeks of release.

### Postie avatar creator + surface across app  (was #113, originally v1.2)

Moved here after v1.4 Trust & safety and v1.5 Resilience. PR #113 is non-draft and fully tested
(`flutter analyze` clean, 98 + 227 tests passing); blocked only on manual QA
+ deploy. Avatars surface naturally on the v1.6 engagement surfaces (live
leaderboards, friend cards, profile headers), so bundling them is the
right pairing.

- Settings → **Your postie** lets players build a Postman James-style avatar from swappable parts (skin, head, hair, eyes, nose, facial hair, hat, glasses, background).
- Saved config persists to `users/{uid}.avatar` and renders on friends list, both leaderboard tabs, user profile header, settings header. Falls back to initials when no avatar is set.
- Cloud Functions (`startScoring`, `updateDisplayName`, `newDayScoreboard`) embed the avatar map into leaderboard entries so the global tab renders avatars without an N+1 user-doc read.
- Firestore rules extended to permit a user to write only their own `avatar` map (size-capped at 20 keys).

Pre-merge:

1. Rebase #113 onto `master` (it has been sitting through v1.3–v1.5 — expect conflicts in `leaderboard_screen.dart`, `friends_screen.dart`, `user_profile_page.dart`, `_leaderboardUtils.ts`, `startScoring.ts`, which v1.5 splits into `_claimCore.ts`).
2. Run the manual checklist: Settings → Your postie → cycle parts → Save → confirm avatar shows in Friends list, both Leaderboard tabs, Profile header. Re-open creator → confirm saved state loads. Claim a postbox → confirm new leaderboard entry carries the avatar.
3. `firebase deploy --only firestore:rules,functions`.
4. Merge.

Long-tail follow-ups (do as separate PRs after avatars land):

- Avatar unlock tiles tied to v1.7 streak rewards (e.g. a "Centurion" hat at 100-day streaks).
- Avatar appears in v2.0 BigQuery export as a cohort dimension (no PII — just style choices).

### Live leaderboard with overtake animations  (was #104)

Replace the `FutureBuilder` fetch of `leaderboards/{period}/entries` with `collectionSnapshots()`. Wrap in `AnimatedList` keyed by `uid`; diff orderings drive insert/remove/move. Reuse `flutter_animate` (landed in v1.2) for a ~1.2 s gold highlight flash on rank change.

Keep top-50 limit to cap listener cost. Provide a `MediaQuery.disableAnimations` short-circuit on slow devices. No backend changes — `startScoring` already writes deltas. Flag: `feature_live_leaderboard` in Remote Config.

### Postbox of the Day  (was #106)

Daily-rotating "POTD" worth 2× points. Morning push with a rough region hint; in-app banner above the nav bar when active and unclaimed.

Data: `postboxOfTheDay/{YYYY-MM-DD}` = `{postboxId, monarch, regionOutcode, announcedAt, expiresAt}` and an atomic `postboxOfTheDay/current` pointer. Claims get an optional `bonusReason: "potd"` tag.

Selection: scheduled function at 06:00 London. Weighted-random favouring rarer monarchs, excluding last-30-day picks (`postboxOfTheDay/history`), requiring at least one historical claim (avoid dead locations). Weight penalty for low-density regions.

Push: topic `potd` (or `rare_finds`), no exact coordinates. `startScoring` checks `postboxOfTheDay/current.postboxId` and applies 2× multiplier; logs `bonusReason: "potd"` and emits `potd_claimed` Analytics event.

Soft-launch: enable without 2× multiplier for a week to validate selection + notification; turn on the multiplier in week 2.

### Weekly and monthly recap  (was #111)

Sunday 18:00 London scheduled function. For each user with ≥1 claim that week: aggregate claims, compute rank delta vs. previous week, pick a James line keyed by the most interesting stat ("A record week, squire!"). Mirror monthly on the 1st.

Data: `recaps/{uid}/periods/{YYYY-WW}` and `recaps/{uid}/periods/{YYYY-MM}` = `{claims, uniquePostboxes, rarestMonarch, topFriend, rankDelta, generatedAt}`. Idempotent — skip if recap doc already exists.

Client: `lib/recap_screen.dart` full-bleed scroll narrated by James. Share button uses `share_plus` to render a PNG card. Badge dot on home tab for unread recaps. Batch writes in chunks of 400. Backfill-safe — on first run, only generate the current week forward.

### Friend challenges (head-to-head)  (was #101)

Users challenge friends to short-term contests ("First to 5 EVIIR boxes this week"). Winner gets a cosmetic badge. No real-world wagering.

Data: `challenges/{id}` with `{fromUid, toUid, type, target, goalValue, startAt, endAt, status, fromProgress, toProgress, winnerUid?, createdAt}`. Append-only `challenges/{id}/events/{eventId}` for audit. Badge appended to `users/{uid}.badges[]`.

Types: `first_to_n_rare`, `most_claims`, `longest_streak`.

Callables: `createChallenge` (validates friendship, window ≤ 7 days), `acceptChallenge`, `declineChallenge`, `cancelChallenge` (pre-acceptance only).

Progress: Firestore trigger `onClaimCreated` updates active challenges. FCM on invite/accept/overtake/completion using existing `_notifications.ts`. Cap concurrent active challenges per user at 3.

---

## v1.7 — Collection & content  (Deferred)

**Theme**: turn the claim loop into a collection loop. Most users today see a
points number; few have a sense of *which* cyphers they've seen or what's
left to discover. The data is all there — the surface isn't.

**Ship gate**: a player who's claimed at least three different cyphers can
see their progress as a visible 9-tile "collection" on the home tab;
≥ 20 % of WAU open the encyclopedia / collection screen in the first week.

### Achievements & badges system  (new)

Persistent rewards across claims to give long-term play a shape beyond the
daily leaderboard. CLAUDE.md already lists "achievements/badges" as a
suggested engagement feature; concrete proposal:

Initial badges (~12):

- **First steps** — first claim; first 10; first 50; first 500.
- **Collector** — claim ≥ 1 of each of 5 / 7 / 9 cyphers.
- **Rare bird** — claim an `EVIIIR` or `CIIIR`.
- **Counties** — claim in 5 / 25 / 50 distinct counties (already tracked via `users/{uid}/countyStats/{slug}`).
- **Streak keeper** — 7-day, 30-day, 100-day, 365-day streaks (`streak_service.dart` already exists).
- **Walker** — total accumulated distance through Route Mode ≥ 10 km / 50 km / 100 km.

Data:

- `users/{uid}.badges[]` (array of `{id, awardedAt}`).
- `users/{uid}/badgeProgress/{badgeId}` — server-side progress counters for badges that aren't single-event awards.
- `badgeDefinitions/{id}` — server-readable definitions, loadable from Remote Config so new badges ship without a client release.

Implementation:

- New `functions/src/_badges.ts` pure helpers (`evaluateBadgesForClaim(prevStats, newClaim)` returning a list of newly-earned badge ids). Reuse the `_recomputeScores.ts` re-aggregation pattern so badges survive cypher corrections.
- `startScoring` calls the evaluator; new badges trigger a James line via the existing FCM social-notification path and an in-app toast on next foreground.
- New `lib/badges_screen.dart` + a compact "trophy shelf" widget on `user_profile_page.dart`.

Risk: badge inflation — keep the initial set small (~12), tune via Remote Config before adding more.

### Postbox encyclopedia / collection album  (new)

A "passport" of the nine royal cyphers, each shown as a tile that locks until
first claim. Tap a cypher → detail page with photos (user's own if claim
photos ever ship), monarch portrait/lore, count claimed, rarest reference
(`ref` field) claimed, map of personal claim locations for that cypher.

Data already available — no new collections:

- `monarch` per claim is already stored.
- `royal_cypher:wikidata` is in OSM but not currently imported — extend `functions/import_postboxes.js` to capture `wikidata` and surface deep links to the Wikipedia article for each cypher (single read for an Encyclopedia page, no per-postbox call).
- `users/{uid}/countyStats/{slug}` already powers the heatmap and can join into the encyclopedia.

New surface:

- `lib/encyclopedia_screen.dart` — 9-tile grid with locked silhouettes.
- Per-cypher detail uses `MonarchInfo` for label/colour/era, joins to `claims` filtered by `monarch` for personal stats.
- Hook the encyclopedia into the bottom-sheet on `claim.dart` when a new cypher is unlocked ("Welcome to the EVIIR club, squire").

Implementation hint: reuse `_FuzzyCompassPainter` to draw a per-cypher "this is where you've found these" mini-map (without exact coords — sectors only, same privacy rule as Nearby).

### Streak rewards  (new)

`streak_service.dart` + `_streakUtils.ts` already track daily streaks; nothing
rewards them today.

- 7 days → +1 point bonus on the next claim (modest).
- 30 days → unlock a James line set ("monthly regular" tier).
- 100 days → unlock a "Centurion" badge + a hat tile in the avatar creator.
- 365 days → unlock a "Year-rounder" badge + Postman James says your name (uses display name).

Implementation: backend-only. `_streakUtils.computeNewStreak` already returns
the new streak; pipe through a `_streakRewards.ts` pure helper that returns
`{ bonusPoints, unlocks }` and let `startScoring` apply both. Avatar unlocks
write to `users/{uid}.avatarUnlocks` (set), read by the avatar creator.

### Pre-built heritage walking tours  (new)

Extend Route Mode with **curated tours** ("Bath's Victorian boxes",
"Marylebone Monarchs", "Edinburgh New Town round"). The Route Mode
infrastructure (`_routePlanner.ts`, corridor / orienteering, `routePostboxes`
callable) already handles the planning maths — this just adds saved
itineraries.

Data:

- `tours/{slug}` = `{ title, region, descriptionMd, startGeopoint, paceDefault, estDurationMins, postboxIds: string[], coverImagePath?, curator }`.
- `tourCompletions/{uid}/{slug}` — per-user "started / completed" flag with progress.
- Tours are curated initially; later, an admin tool (mirror of `admin_reports_screen.dart`) can promote a user-submitted route.

Client:

- New tab in `destination_picker_screen.dart`: "Pick a tour" alongside the existing map/search picker. Selecting a tour locks the corridor settings to the tour's recommended values.
- `live_route_screen.dart` shows tour progress ("3 / 7 boxes claimed") in a header.

Rollout: ship with 3 curated tours covering a small, dense, walkable city (Bath / Cambridge / York). Soft-launch behind `feature_tours_enabled` Remote Config.

### Map filters and postbox detail-on-tap  (new)

The map (`lib/widgets/postbox_map.dart` / `lib/county_heatmap.dart`) currently
shows POI icons but tapping doesn't open a meaningful detail. Add:

- **Filters bar**: toggle cyphers on/off, "show only unclaimed" / "show only claimed" / "all". Persist in `app_preferences.dart`.
- **Postbox tap → bottom sheet**: monarch + cypher reference, when *anyone* last claimed it (date only, no UID), distance + "walk here" CTA that fires Route Mode with this postbox as the destination.
- **Personal pin colour**: a small dot overlay on POI icons for "you've claimed this one", reusing the user's `mapColor` setting.

No backend changes — `nearbyPostboxes` already returns enough metadata for the bottom sheet (modulo the "last-claimed date" which is a small `claims` aggregation per box; cache in a `postboxStats/{id}` doc, refreshed by a Firestore-triggered function on claim writes to avoid scan-time cost).

---

## v1.8 — Reach (iOS, localisation)  (Deferred)

**Theme**: open the door to users outside the current Android-phone + Wear OS + Android Auto + (eventual) XR funnel.

**Ship gate**: signed iOS build available on TestFlight; at least one non-English locale ships and is selectable in Settings; no English-language strings remain in user-facing widgets per `flutter_lints` rule; App Check `AppleProvider` attesting on iOS with denial rate < 1 % (the Android half already enforced in v1.5).

### iOS support  (new)

CLAUDE.md notes `firebase_options.dart` has iOS config but no `Podfile` exists. Real work:

- `cd ios && pod install` (generates the Podfile).
- Verify `Info.plist` permissions: `NSLocationWhenInUseUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription`, `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription` (last two already present per CLAUDE.md).
- Wire `AppleProvider` (`DeviceCheck` / `AppAttest`) for App Check (see the App Check item below — server-side enforcement already landed in v1.5, so iOS clients will be *rejected* until this is done; it is a launch blocker, not a nice-to-have).
- App Store Connect listing: name, screenshots, age rating, privacy nutrition labels (matching what the GDPR plan in v1.4 implements).
- Mac Catalyst evaluation — `firebase_options.dart` already has a macOS config; trivial scope or skip.

Smoke-test gates: login (email + Google), nearby scan, claim quiz, report submission with photo, route mode end-to-end. Wear/Android Auto are not relevant on iOS.

Backend risk: callable region pinning (v1.3, done) and App Check enforcement (v1.5, done) both touch iOS. Because v1.5 turns on `enforceAppCheck` server-side, an iOS build without `AppleProvider` will fail every callable — wire it before the first TestFlight drop.

### App Check — iOS provider + remaining surfaces  (was #96; Android half done in v1.5)

**v1.5 already turned on `enforceAppCheck` for the claim callables** (it was a prerequisite for accepting client-supplied timestamps). What remains here is the iOS provider and the non-Functions surfaces.

1. iOS: activate `AppleProvider` (`DeviceCheck` / `AppAttest`). **Launch blocker** — with server-side enforcement already live, an iOS build without it fails every callable.
2. `AndroidDebugProvider` for dev — token committed to developer machines, not the repo.
3. Extend enforcement from the claim callables to the remaining ones, plus Firestore, Storage, RTDB in the Firebase Console.
4. Cloud Monitoring alert on App Check denial-rate spikes.

Roll each new surface out in **monitor** mode for 7 days, then **enforce** if denial rate < 1 %. Keep a break-glass Remote Config flag to disable explicit checks during provider outages.

⚠️ **Known risk carried from the Android Auto work**: the off-Play `auto` flavour uses `AndroidPlayIntegrityProvider`, which expects Play distribution. Confirm how it behaves under enforcement before v1.5 ships, or that flavour's claim button breaks.

### Localisation infrastructure  (new)

Currently English-only and a UK-centric game. The British Isles' minority and regional languages are on-brand and a strong differentiator — leaning into them also flatters the heritage angle (Victorian boxes, monarch eras) more than a generic French / German launch would.

**Candidate locales** (in rough order of cultural fit + translator availability):

| BCP 47 | Language | Notes |
|---|---|---|
| `cy` | Welsh | Statutory bilingual signage across Wales; high translator availability. |
| `gd` | Scottish Gaelic | ~57k speakers, strong heritage angle. Official status in Scotland. |
| `ga` | Irish | Official in Ireland; opens up RoI postbox coverage if the game ever crosses the border. Note that NI doesn't have An Post boxes but the diaspora overlap is real. |
| `sco` | Scots | Lowland Scots (Wikipedia-scale community; sister language to English). Cheap to localise because the vocabulary overlap is high; the personality shift on James lines alone is worth it. |
| `kw` | Cornish | Revived language, small but active community. Cornish postboxes are iconic in their own right. |
| `gv` | Manx | Optional stretch — IoM has Manx-bilingual signage; tiny speaker base but symbolic. |

Launch tier ≈ `cy` + `gd` + `sco` (highest fit, English-adjacent translation cost is low). Second tier `ga` + `kw`. `gv` and any further additions on demand.

Steps (the `flutter-setup-localization` skill summarises this):

1. `flutter_localizations` + `intl` dependencies; `generate: true` in `pubspec.yaml`; `l10n.yaml` config.
2. Extract every hardcoded user-facing string from `lib/` into ARB files. `james_messages.dart` (399 lines) is the long pole — keep its keys stable; translate the values.
3. Add Settings → "Language" picker. Default to `Platform.localeName` with English fallback; show the user the *autonym* (e.g. "Cymraeg", "Gàidhlig", "Gaeilge", "Scots", "Kernewek", "Gaelg") next to the English name in the picker.
4. Translate `james_messages.dart` to the launch tier first; English variants stay authoritative as the canonical source for any new strings.
5. Long-run: Lokalise / Crowdin pipeline so translators don't touch the repo. `sco` may need an in-house pass since few CAT tools cover it.

Risk: every future PR must add ARB entries; enforce via a CI lint that fails on hardcoded user-facing strings (`flutter_lints` doesn't catch this by default — write a small `analyzer_plugin` or grep step).

Backlog idea (depends on this): regionally-flavoured James — a Welsh James for `cy`, a Scottish James for `gd`, a "wee blether" Scots James for `sco`, an Irish James for `ga` — complete with the existing voice-line plan (Backlog).

---

## v2.0 — Growth (Analytics + experimentation)  (Deferred)

**Theme**: switch from anecdote-driven to data-driven product decisions.
**Ship gate**: BigQuery export populating daily; at least one A/B experiment ramped to 100 % with a measured winner; topic broadcasts capped + opt-in.

### Custom Analytics events and BigQuery export  (was #95)

Instrument key actions + enable Firebase Analytics → BigQuery daily export so cohort/funnel/retention analysis runs in SQL.

Initial events: `claim_success` (monarch, region outcode, points, isFirstOfDay), `claim_failed_quiz`, `nearby_viewed`, `compass_viewed`, `friend_added`, `leaderboard_viewed`, `james_line_shown`, `streak_broken`, `signup_complete`.

Typed wrapper `lib/services/analytics_service.dart`. Strict param validation. Privacy: no PII, no exact coordinates (use outcode); opt-out toggle in settings.

BigQuery: enable linked dataset in console. Add `views/` directory with SQL for common slices (DAU, funnel, claim density by region); document each view in `docs/analytics/`. Ship event wrapper first, enable BigQuery export when there's at least one view ready.

### A/B testing onboarding and UX experiments  (was #94)

Firebase A/B Testing on top of Remote Config conditions (depends on the v1.4 Remote Config work and the v2.0 Analytics work landing first).

Candidate experiments: onboarding length (current James intro vs 2-screen condensed; metric `sign_up_complete`), compass granularity (8 vs 4 sectors; metric `claim_success`), empty-state CTA copy (metric `nearby_retry`).

Params as string Remote Config entries (`exp_onboarding_variant`, `exp_compass_sectors`, `exp_empty_copy`) with defaults; client reads active variant and logs `experiment_exposure` for slicing.

Risk: small DAU → long test duration. Pre-register minimum sample size; avoid overlapping experiments on the same surface.

### FCM topics per region and monarch-era  (was #100)

Topic taxonomy: `region_{outcode}`, `monarch_{code}`, `rare_finds`.

On login, subscribe to `monarch_*` for opted-in monarchs (default: all rare tiers) and `rare_finds`. On "use my location" grant, subscribe to `region_{outcode}` and store the outcode locally; on change, unsubscribe old, subscribe new.

New `onRareClaim` Firestore trigger sends to `rare_finds` / `monarch_{code}` / `region_{outcode}` when monarch is rare. Rate-limit per topic to max 3 messages per 24 h using `notificationRateLimits/{topic}` counter doc. Settings: "Rare find alerts" and "Claims in my area" toggles mirrored to `users/{uid}/notificationPrefs`. Quiet hours 22:00–08:00 local.

---

## Backlog — Speculative big-rocks

No release commitment yet. Promote into a versioned release when there's a clear product reason.

### Firebase Hosting + App Links / Universal Links  (was #102)

Dynamic Links is deprecated and removed. Replace with Hosting-served deep-link landing pages and the required Android `assetlinks.json` / Apple AASA files.

Initial surfaces: `/claim/{claimId}`, `/u/{uid}`, `/challenge/{id}`. New `hosting/` directory with `firebase.json` hosting section, simple landing, `/.well-known/assetlinks.json`, `/.well-known/apple-app-site-association` (served as `application/json`). Cloud Functions rewrites render server-side HTML with OG tags and a JS attempt to open the app via intent URI.

Flutter uses `app_links` package. Android: `android:autoVerify="true"` intent filter for the Hosting domain; `assetlinks.json` contains the app's signing cert SHA-256 (debug and release certs differ — serve both). iOS: Associated Domains capability `applinks:postbox.example`.

### Postman James voice lines  (was #103)

Optional voiced layer. Short MP3/OGG lines hosted in Cloud Storage, downloaded lazily, on-device LRU cache (30 MB max).

Asset pipeline: each line has an id (`idle_rain_01`); recorded by a voice artist, normalised -16 LUFS, exported OGG Opus 24 kbps (~20 KB/line); stored at `james-audio/{locale}/{lineId}.ogg`. `james-audio/{locale}/index.json` lists `{lineId: {path, durationMs, hash}}`. Remote Config `james_audio_index_url_{locale}` points at the index (versioned).

`lib/services/james_audio_service.dart` fetches the index on login, plays via `just_audio` when `JamesController` shows a line with an `audioId`. Extend `lib/james_messages.dart` entries with optional `audioId`. Fall back silently to text-only.

Settings toggle "James speaks aloud" (default OFF). Respect device silent mode. Pre-warm only on Wi-Fi; respect data-saver. Accessibility: never replace text with audio alone.

### Realtime Database presence for online friends  (was #108)

Small "online now" dot on friend cards and profile. RTDB `onDisconnect` is a better fit than Firestore for cost and latency.

New RTDB in the same region as Firestore (e.g. `europe-west1` once v1.3 lands). `PresenceService` writes `/status/{uid}` = `{state: "online"|"background"|"offline", lastChanged: ServerValue.TIMESTAMP}` on sign-in and registers `onDisconnect().set({state:"offline"})`. App lifecycle drives transitions.

Mirror to Firestore on transitions via an RTDB-triggered Cloud Function (`functions/src/presence.ts`) at `users/{uid}.presence` for non-listening contexts. Friends screen subscribes directly to `/status/{friendUid}` refs in a batched listener.

Gate behind `feature_presence_enabled`. Privacy: hide presence if the user toggles "invisible mode".

### Claim photos with moderation  (was #109)

Photo attached to a claim ("postbox selfie"). Private by default; moderated before display.

Storage layout: `claims-photos/{uid}/{claimId}/original.jpg` (user-write, user-read), `thumb.jpg` (created by function). Storage rule caps at 5 MB.

`onClaimPhotoUploaded` Storage trigger runs Cloud Vision `SafeSearchDetection`; if adult/violence/racy > LIKELY, delete both objects and write `moderation/flags/...`; otherwise generate a 512 px thumb and mark the claim `photoReady: true`. Cost-aware alternative: ML Kit on-device pre-check before upload.

Client: `image_picker` + `flutter_image_compress` (≤ 1280 px, JPEG q80). Retry-safe uploader with resume. Per-user 500-photo quota.

Friends-visible mode is out of scope. Photos stay private.

### Transactional email via "Trigger Email" extension  (was #110)

Install the `firebase/firestore-send-email` extension; watches `mail/{autoId}` = `{to, template:{name, data}, delivery?}`. Templates at `mailTemplates/{name}` (Handlebars).

Email types: `friend_added`, `weekly_recap`, `challenge_invite`, `account_deleted`. Cloud Functions hooks: extend `onFriendAdded` (already FCM-driven) to also write a mail doc when `user.emailNotifications.friendAdded !== false`. Weekly recap function writes mail docs in the same pass as recap docs.

Provider: SendGrid free tier (~100/day) for beta; swap to Postmark / SES at scale. Credentials via `firebase functions:secrets:set` — never in repo.

Compliance: unsubscribe link in every email deep-linking to settings; respect `users/{uid}/emailPrefs`; on account deletion, remove pending mail docs first. Configure SPF/DKIM/DMARC on the sending domain.

### OCR cypher recognition via ML Kit  (new)

Replace (or augment) the claim quiz with a camera-based OCR pass that
reads the cypher off the postbox. Solves two problems at once:

1. **Anti-cheat**: a photo of the actual cypher is presence evidence
   beyond GPS, harder to spoof than mock-location.
2. **UX**: the current quiz can feel arbitrary on first encounters.

Implementation sketch:

- `google_mlkit_text_recognition` (on-device, no API cost). Match the recognised text against `MonarchInfo.all` with fuzzy normalisation ("E II R" → `EIIR`, "G R" → `GR`, etc.).
- If OCR returns a clear winner → auto-fill the quiz answer and let the user confirm in one tap.
- If ambiguous → fall back to the existing quiz UI.
- Photo is optionally retained as a thumbnail attached to the claim (overlaps with the Backlog "claim photos" item — implement that first or share storage).

Risks:

- Worn / vandalised cyphers → OCR fails; quiz fallback covers it.
- Accessibility — text recognition shouldn't be required, so the quiz path stays the canonical input.
- Battery: ML Kit on-device is cheap but not free; cap to one OCR pass per claim attempt.

### Activity feed (privacy-controlled)  (new)

A timeline tab in the Friends section showing "Alex claimed an EVIIR
in BS6 this morning" with the existing display name + avatar. No exact
coordinates — outcode only, matching the existing privacy rule.

Data:

- `activityFeed/{uid}/items/{ts}` — denormalised mirror written by a Firestore trigger on `claims/{id}` create, fanned out to each of the claimant's friends. TTL 30 days via a daily cleanup function (or Firestore TTL policy).
- Per-user toggle `users/{uid}/notificationPrefs.activityFeedEnabled` (default true; opt-out hides the user from friends' feeds entirely).

Client:

- New tab inside `friends_screen.dart` ("Feed" alongside "List").
- Pull-to-refresh + paginated stream listener on the user's own `activityFeed/{uid}/items` collection.

Engagement risk: feeds drive comparison and can demoralise. Keep it private to friends and never show "ranks improved by X" — only "claimed Y".

### Block / mute  (new)

Today the friend system is bilateral (add by UID) with no way to drop a
friend or block someone from re-adding you. Small but important once the
activity feed or challenges land.

- `users/{uid}.blocked[]` (array of UIDs).
- Firestore rules enforce: if `target.uid` is in `request.auth.uid`'s `blocked`, they can't appear in friends queries (server-side filter in `friends_screen.dart`) and can't initiate a challenge.
- "Block" action in the friend-card overflow menu and on `user_profile_page.dart`.
- "Blocked users" list in Settings to unblock.

No backend changes beyond rule updates and a small fan-out adjustment so the activity feed (above) honours the block.

### Churn-risk retention push via BigQuery ML  (was #97)

Depends on the v2.0 Analytics + BigQuery export. Firebase Predictions is deprecated. Modern path: train a BQ-ML logistic regression on the Analytics export.

Features: `daysSinceLastClaim`, `totalClaims`, `friendsCount`, `streakLength`, `sessionsLast7d`. Label: "did not return in next 7 days". Daily scheduled query writes predictions to GCS; Cloud Function `sendChurnPushes` reads predictions, filters `risk > 0.7 AND notificationPrefs.retentionEnabled`, sends one FCM per user per 7-day window.

Message: James-voiced and specific. "Your streak's looking lonely without you, squire. A VR box in BS6 is waiting." Quiet hours and per-week frequency caps.

Roll out the BQ model with monitoring only first; review prediction quality manually against actual return behaviour for 2 weeks; enable pushes to 10 % first.

---

## Done

- **#117** — Postbox-data problem reporting, admin review & OSM corrections.
- **#121** — Walk-to-destination route mode with corridor + detour scoring.
- **v1.2** — Intro polish: `flutter_animate` effects wired across every intro step
  (`7ea9820` + entrance-animation follow-up), confetti on Mega Points, intro smoke
  test. Shipped as `1.2.0+13`.
- **v1.3** — Platform foundations: EU region migration (Cloud Functions →
  `europe-west2`, Firestore → `eur3`) deployed; Firebase Performance custom traces
  across 6 flows; Crashlytics custom keys + non-fatal logging; Android Gradle 8.14
  / AGP 8.11.1 bump (Built-in Kotlin not yet viable). Shipped as `1.3.2+16`. The
  Remote Config game-balance work was split out to v1.4; operational migration
  follow-ups in `docs/plans/v1.3-region-migration-followups.md`.

## Open exploration (no release commitment)

- **#120** — Android XR scaffold (draft). Exploratory; revisit when Jetpack XR artefacts are out of alpha. Close after 6 months untouched.

---

## How to use this doc

1. When starting a v-numbered release, copy its **Ship gate** into the release PR's body so it's the merge checklist.
2. Promote one item at a time from Queued → In flight on a feature branch named `feat/<area>` or `chore/<area>`.
3. Update this file's status when work begins (`Queued` → `In flight`) and again when shipped (move into the matching version's **Done** sub-list, or to the top-level Done list with the merged PR link).
4. Keep entries flat. Deep design detail lives in the PR body, not here.
