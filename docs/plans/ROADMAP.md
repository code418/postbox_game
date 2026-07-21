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
| **v1.5** | Engagement & avatars (social loops + Postie avatar) | Deferred |
| **v1.6** | Collection & content | Deferred |
| **v1.7** | Reach (iOS, localisation, App Check) | Deferred |
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
> moved down to **v1.5** after Trust & safety. PR #113 is non-draft and
> ready, but will sit waiting through v1.3 and v1.4. **Risk**: long-lived
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

## v1.4 — Trust & safety  (In flight)

**Theme**: harden the platform now that we can see what's happening (v1.3 observability).
**Ship gate**: account-deletion flow tested end-to-end in staging; impossible-travel detector in shadow mode logging flags but not blocking; Remote Config drives `claim_radius_meters` and `points_by_monarch` end-to-end (client + Cloud Functions) with the safety bounds enforced; telemetry disclosure live with analytics on by default and a working opt-out (DebugView goes silent when the Settings → Privacy toggle is switched off); `exportMyData` returns a complete bundle in staging; `dataRetentionSweep` executed once in staging with logged strip/delete counts.

> **Status** (branch `feat/v1.4-trust-safety`, `1.4.0+18`): all four workstreams
> implemented (Remote Config balance, GDPR deletion, shadow-mode abuse, and the
> GDPR compliance finish below); `flutter analyze` + Dart tests + functions
> lint/tests green. Remaining before ship: the manual staging passes (account
> deletion, consent DebugView check, export bundle, one forced retention-sweep
> run) and the Remote Config console setup (publish `claim_radius_meters` +
> `points_by_monarch` to the client AND server templates with values equal to
> the code defaults). Two roadmap divergences, both deliberate: (1) GDPR uses a
> **self-contained `onUserDeleted` function, not the Delete-User-Data extension**
> (the extension can only delete, not anonymise claims, which would break
> leaderboard integrity); (2) abuse **enforcement/voiding stays deferred
> (Phase 2)** — the ship gate requires shadow mode, so `SHADOW_MODE` remains
> `true`. Remote Config was scoped to the ship-gate pair only (no
> `quiz_required_streak`, other constants left hard-coded).

> **App Check enforcement moved to v1.7** (it's gated on iOS `AppleProvider`
> wiring, which lands in v1.7's iOS work). See the App Check item under v1.7.

### Remote Config for game balance and copy  (was #107, moved from v1.3)

> ✅ Implemented (ship-gate pair only). Client: `RemoteConfigService.claimRadiusMeters`
> + `pointsForCipher`/`pointsByMonarch` (bounds-checked, defaults = constants), force-refetch
> on login. Backend: `functions/src/_config.ts` (`getServerTemplate` + 5-min cache, never
> throws) wired into `startScoring` + `_recomputeScores`. Fallback constants stay canonical
> (guarded by `test/cross_language_sync_test.dart`). Other tunables + `quiz_required_streak`
> intentionally out of scope.

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

> ✅ Implemented as a **self-contained `onUserDeleted` v1 Auth trigger** (europe-west2)
> + `functions/src/_accountDeletion.ts`, NOT the extension (the extension can't anonymise
> claims). Anonymises claims/reports (strips PII incl. the new `deviceIdHash`), hard-deletes
> user docs + `report_photos/` (and future-proof `claims-photos/` via
> `storagePrefixesForUser`), audit counter at `deletions/{day}`. Flutter re-auth + `User.delete()`
> in `lib/user_repository.dart`, Settings "Delete account" UI. Helpers unit-tested; full-flow
> e2e is the staging pass below.

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

> ✅ Implemented in **shadow mode** (`SHADOW_MODE = true`, stays that way per the ship gate).
> All four signals now fire: impossible-travel, out-of-window, coord-cluster, and the new
> **repeated-device** signal (`repeatedDeviceSignal` + `evaluateClaimSignals` in
> `_abuseSignals.ts`, wired in `onClaimCreated`; client sends a stable per-install
> `deviceIdHash` via `lib/services/device_id_service.dart`; composite index added). Flags →
> `moderationFlags`, trust decay → `trustScores`, admin review UI `admin_abuse_screen.dart`.
> Enforcement / claim-voiding remains the deferred **Phase 2** below.

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

### GDPR compliance finish (consent, DSAR export, retention)  (new)

> ✅ Implemented. Closes the four blockers a full GDPR review (2026-07-17) found
> after the deletion work shipped: no consent/transparency surface, no
> self-serve right-of-access, no retention limits, and a partial report
> anonymisation. Also fixed the dependency skew that broke Dart test loading
> (`firebase_core_platform_interface` ^8.0.0 + `fake_cloud_firestore` 4.2.0).

- **Telemetry disclosure + opt-outs (analytics ON by default)**: all three
  streams (analytics, Crashlytics, Performance) run under legitimate interest,
  on by default. The final intro step (new users) and the one-time `ConsentGate`
  prompt in `lib/consent_screen.dart` (existing installs) disclose this with a
  pre-enabled analytics switch; Settings → Privacy has opt-out toggles for all
  three, persisted in `lib/consent_preferences.dart` (SharedPreferences,
  pre-login-safe) and applied by `applyStoredTelemetryPreferences()` at every
  cold start. The `firebase_analytics_collection_enabled=false` manifest flag is
  kept so opted-out users never leak events before the runtime toggle applies.
  **Product decision 2026-07-17**: analytics was briefly opt-in per ICO guidance
  and deliberately switched to opt-out — a known residual compliance risk
  (ICO/PECR treat analytics as consent-requiring), accepted for now.
- **Privacy policy**: single source `assets/legal/privacy_policy.md`, rendered
  in-app by `lib/legal/privacy_policy_screen.dart` (no markdown dep) and mirrored
  at `web/privacy-policy.html` (hosted at `/privacy-policy`, for the Play
  listing); `test/privacy_policy_sync_test.dart` pins the two against each other.
  Content now discloses the device token, anti-abuse records, retention
  schedule, and in-app rights surfaces.
- **DSAR export (Art. 15/20)**: `exportMyData` callable returns a JSON bundle of
  every per-user store (mirrors `_accountDeletion.ts`'s authoritative list, incl.
  moderation flags and the Auth record); Settings → Privacy → "Download my data"
  shares it as a file via `share_plus`. Claims capped at 20k newest with a
  truncation flag (10 MB callable limit).
- **Retention (Art. 5(1)(e))**: `functions/src/dataRetention.ts` nightly sweep
  (03:30 London) — strips `CLAIM_PII_FIELDS` off claims after 90 days
  (watermark-paged, never rescans), purges report photos/notes 30 days after
  review (Storage blobs + doc fields), deletes `moderationFlags` after 180 days.
  Sweep chosen over Firestore TTL deliberately (backfill needed either way,
  compliance-evidence logs, unit-testable).
- **Erasure gap closed**: `anonymiseReportsForUser` now strips
  `REPORT_PII_FIELDS` (note + photos incl. EXIF GPS and uid-bearing storage
  paths); report `lat`/`lng` kept for pending-review integrity (documented).
- **Hygiene**: `audit_*` exports gitignored and evicted from the repo root;
  `audit_user_claims.js` defaults to `./audit_exports`; `startScoring.ts`'s
  deviceIdHash comment corrected (random install token, not a hardware hash).

Risk: the first sweep night backfills history in bounded pages (~6k docs/night)
— watch the `pagesRemaining` log until the backlog drains. iOS
(`FirebaseAnalyticsCollectionEnabled`) is a v1.7 checklist item.

---

## v1.5 — Engagement & avatars  (Deferred)

**Theme**: build the daily-return loop and the friend-pressure loop on top of the now-stable v1.4 platform — and ship the visible-identity work (Postie avatars) so users have something to flex with on the new live leaderboards.
**Ship gate**: DAU / WAU lift measurable in Analytics; POTD claim rate ≥ 30 % of DAU; weekly recap engaged-with by ≥ 25 % of recipients; avatar coverage > 50 % of WAU within two weeks of release.

### Postie avatar creator + surface across app  (was #113, originally v1.2)

Moved here after v1.4 Trust & safety. PR #113 is non-draft and fully tested
(`flutter analyze` clean, 98 + 227 tests passing); blocked only on manual QA
+ deploy. Avatars surface naturally on the v1.5 engagement surfaces (live
leaderboards, friend cards, profile headers), so bundling them is the
right pairing.

- Settings → **Your postie** lets players build a Postman James-style avatar from swappable parts (skin, head, hair, eyes, nose, facial hair, hat, glasses, background).
- Saved config persists to `users/{uid}.avatar` and renders on friends list, both leaderboard tabs, user profile header, settings header. Falls back to initials when no avatar is set.
- Cloud Functions (`startScoring`, `updateDisplayName`, `newDayScoreboard`) embed the avatar map into leaderboard entries so the global tab renders avatars without an N+1 user-doc read.
- Firestore rules extended to permit a user to write only their own `avatar` map (size-capped at 20 keys).

Pre-merge:

1. Rebase #113 onto `master` (it has been sitting through v1.3 and v1.4 — expect conflicts in `leaderboard_screen.dart`, `friends_screen.dart`, `user_profile_page.dart`, `_leaderboardUtils.ts`, `startScoring.ts`).
2. Run the manual checklist: Settings → Your postie → cycle parts → Save → confirm avatar shows in Friends list, both Leaderboard tabs, Profile header. Re-open creator → confirm saved state loads. Claim a postbox → confirm new leaderboard entry carries the avatar.
3. `firebase deploy --only firestore:rules,functions`.
4. Merge.

Long-tail follow-ups (do as separate PRs after avatars land):

- Avatar unlock tiles tied to v1.6 streak rewards (e.g. a "Centurion" hat at 100-day streaks).
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

## v1.6 — Collection & content  (Deferred)

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

## v1.7 — Reach (iOS, localisation)  (Deferred)

**Theme**: open the door to users outside the current Android-phone + Wear OS + Android Auto + (eventual) XR funnel.

**Ship gate**: signed iOS build available on TestFlight; at least one non-English locale ships and is selectable in Settings; no English-language strings remain in user-facing widgets per `flutter_lints` rule; App Check enforced server-side with denial rate < 1 % in monitor mode.

### iOS support  (new)

CLAUDE.md notes `firebase_options.dart` has iOS config but no `Podfile` exists. Real work:

- `cd ios && pod install` (generates the Podfile).
- Verify `Info.plist` permissions: `NSLocationWhenInUseUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription`, `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription` (last two already present per CLAUDE.md).
- Wire `AppleProvider` (`DeviceCheck` / `AppAttest`) for App Check (see the App Check enforcement item below — the two land together in v1.7).
- App Store Connect listing: name, screenshots, age rating, privacy nutrition labels (matching what the GDPR plan in v1.4 implements).
- Mac Catalyst evaluation — `firebase_options.dart` already has a macOS config; trivial scope or skip.

Smoke-test gates: login (email + Google), nearby scan, claim quiz, report submission with photo, route mode end-to-end. Wear/Android Auto are not relevant on iOS.

Backend risk: callable region pinning (v1.3, done) and App Check enforcement (a sibling v1.7 item below) both touch iOS — wire `AppleProvider` as part of the App Check work.

### App Check enforcement audit and hardening  (was #96, moved from v1.4)

App Check is configured client-side for Android release (`AndroidPlayIntegrityProvider`). Audit and **enforce** server-side. Moved here from v1.4 because iOS `AppleProvider` wiring is part of v1.7's iOS work, so the two are best done together.

1. `AndroidDebugProvider` for dev — token committed to developer machines, not the repo.
2. iOS: activate `AppleProvider` (`DeviceCheck` / `AppAttest`) once iOS builds are wired up (the iOS support item above).
3. Firebase Console: enforce on Cloud Functions, Firestore, Storage, RTDB.
4. Functions code: every callable rejects with `failed-precondition` if `context.app` absent (defence-in-depth on top of platform enforcement). Wrap in `functions/src/_appCheck.ts`.
5. Cloud Monitoring alert on App Check denial rate spikes.

Roll out in **monitor** mode for 7 days, then **enforce** if denial rate < 1 %. Keep a break-glass env var to temporarily disable explicit `context.app` checks during provider outages.

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
