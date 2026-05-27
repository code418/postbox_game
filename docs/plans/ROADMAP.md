# Postbox Game — Roadmap

Working backlog, organised by app release. Current shipped version is
`pubspec.yaml`'s `1.1.0+10`. Each release names a **theme** and a **ship gate**;
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
| **v1.2** | Avatars & polish | In flight |
| **v1.3** | Platform foundations (EU region + observability) | Queued |
| **v1.4** | Trust & safety (App Check, GDPR, anti-cheat) | Queued |
| **v1.5** | Engagement | Deferred |
| **v2.0** | Growth (Analytics + experimentation) | Deferred |
| **Backlog** | Speculative big-rocks | Speculative |

---

## v1.2 — Avatars & polish  (In flight)

**Theme**: ship the visible UX work that's already on a branch.
**Ship gate**: manual QA on #113 passes, deploy is clean, `flutter analyze` + tests green, intro effects wired in.

- **Postie avatar creator + surface across app** — PR #113 (non-draft, full tests).
  Run the manual checklist (Settings → Your postie cycle, friends list, both
  leaderboard tabs, profile header). Then `firebase deploy --only firestore:rules,functions`. Merge.
- **Tier 1 intro polish — `flutter_animate`** — PR #82 (dependency-only).
  Merge after #113 so the assets land together, then file a tight follow-up
  that wires the effects into `lib/intro.dart` (postbox `fadeIn` + `scale`,
  James `slideX` with bounce, Mega Points `shimmer`).

---

## v1.3 — Platform foundations  (Queued)

**Theme**: reduce UK latency and stand up the observability needed to spot regressions, so v1.4's harder changes ship safely.
**Ship gate**: UK round-trip on `nearbyPostboxes` < 150 ms p50; Crashlytics dashboard shows the new custom keys; Remote Config drives at least `claim_radius_meters` end-to-end; Performance traces visible for the 6 trace names below.

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

1. **Pre-flight**: `gcloud firestore export gs://the-postbox-game-backup-eu/pre-migration-$(date +%F)` (create the backup bucket in `europe-west2` first). Tag the repo, freeze deploys.
2. **Region-pin Cloud Functions** (code change, no deploy yet):
   - v2 callables (`nearbyPostboxes`, `startScoring`, `updateDisplayName`, `registerFcmToken`, `userClaimHistory`, `submitReport`, `reviewReport`, `routePostboxes`): add `{ region: "europe-west2" }` to `onCall` options.
   - v2 scheduler (`newDayScoreboard`): add `region: "europe-west2"` alongside `schedule` + `timeZone`.
   - v1 triggers (`onFriendAdded`, `onUserCreated`): wrap with `functionsV1.region("europe-west2")`.
3. **Firestore database move (disruptive — Path A recommended)**:
   1. Maintenance mode via the existing `maintenance_mode` Remote Config flag (per `b721caa`); client renders "we'll be right back".
   2. Final export to `gs://…-backup-eu`.
   3. Delete `(default)` (delete protection is already `DISABLED`).
   4. `gcloud firestore databases create --location=eur3 --database='(default)'`.
   5. Re-deploy `firestore.rules` and `firestore.indexes.json`; wait for indexes to finish before reopening traffic.
   6. `gcloud firestore import` from the backup.
   7. Verify counts on `postbox`, `claims`, `users`, `leaderboards`, `fcmTokens`.
   - Path B (named DB in `eur3`, dual-write, switch reads, retire `(default)`) is the fallback if Path A downtime is unacceptable; **avoid** unless forced, since every `admin.firestore()` call would need to target the non-default DB.
4. **Deploy new functions**: `firebase deploy --only functions` *creates* europe-west2 copies; us-central1 copies are not deleted automatically. Verify all 8 healthy.
5. **Pin Flutter client** to europe-west2 via a single helper `lib/firebase_functions_eu.dart` exposing an `appFunctions` getter. Refactor the 8 callable call sites in `lib/user_repository.dart`, `lib/wear/wear_compass_page.dart`, `lib/notification_service.dart`, `lib/nearby.dart`, `lib/wear/wear_claim_page.dart`, `lib/claim_history_screen.dart`, `lib/claim.dart`. Bump the app version. Keep both regions live until us-central1 invocations drop to zero in Cloud Logging.
6. **Storage bucket** (do last): create `the-postbox-game-eu` in `europe-west2`, regen SDK config via FlutterFire CLI, migrate any objects with `gsutil -m cp -r` (currently nothing referenced from client code).
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

**Rollback**: delete the new `(default)`, re-create in `nam5`, import the pre-migration backup, re-deploy us-central1 functions from the freeze tag, revert the Flutter client `instanceFor` change, ship a hotfix.

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

### Remote Config for game balance and copy  (was #107)

Centralise tunable values so balance, reminder copy, and James cadence change
without a client release. Both client and Cloud Functions read Remote Config.

- Initial params: `claim_radius_meters` (30), `points_by_monarch` (JSON), `james_idle_min/max_seconds`, `daily_reminder_hour_local`, `nearby_radius_meters`, `quiz_required_streak`.
- Client: `lib/services/remote_config_service.dart` with typed getters; fetch-and-activate on app start (min 1 h prod, 0 debug).
- Backend: `_config.ts` admin fetch with 5 min in-memory cache; `_getPoints.ts` honours override with hard-coded fallback; `startScoring` uses `claim_radius_meters`.
- Already partially wired: `b721caa` (`maintenance_mode`/`message` template), `1caca74` (Analytics user properties for audience targeting).
- Rollout: ship client first with defaults equal to current code, then backend, then tune via console.
- Risk: stale client cache hides a bad value — force refetch on login. Cost drift if `points_by_monarch` mis-set — sanity-check function rejecting values outside `[1, 50]`.

---

## v1.4 — Trust & safety  (Queued)

**Theme**: harden the platform now that we can see what's happening (v1.3 observability).
**Ship gate**: App Check denial rate < 1 % in monitor mode; account-deletion flow tested end-to-end in staging; impossible-travel detector in shadow mode logging flags but not blocking.

### App Check enforcement audit and hardening  (was #96)

App Check is configured client-side for Android release (`AndroidPlayIntegrityProvider`). Audit and **enforce** server-side.

1. `AndroidDebugProvider` for dev — token committed to developer machines, not the repo.
2. iOS: activate `AppleProvider` (`DeviceCheck` / `AppAttest`) once iOS builds are wired up.
3. Firebase Console: enforce on Cloud Functions, Firestore, Storage, RTDB.
4. Functions code: every callable rejects with `failed-precondition` if `context.app` absent (defence-in-depth on top of platform enforcement). Wrap in `functions/src/_appCheck.ts`.
5. Cloud Monitoring alert on App Check denial rate spikes.

Roll out in **monitor** mode for 7 days, then **enforce** if denial rate < 1 %. Keep a break-glass env var to temporarily disable explicit `context.app` checks during provider outages.

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

## v1.5 — Engagement  (Deferred)

**Theme**: build the daily-return loop and the friend-pressure loop on top of the now-stable v1.4 platform.
**Ship gate**: DAU / WAU lift measurable in Analytics; POTD claim rate ≥ 30 % of DAU; weekly recap engaged-with by ≥ 25 % of recipients.

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

## v2.0 — Growth (Analytics + experimentation)  (Deferred)

**Theme**: switch from anecdote-driven to data-driven product decisions.
**Ship gate**: BigQuery export populating daily; at least one A/B experiment ramped to 100 % with a measured winner; topic broadcasts capped + opt-in.

### Custom Analytics events and BigQuery export  (was #95)

Instrument key actions + enable Firebase Analytics → BigQuery daily export so cohort/funnel/retention analysis runs in SQL.

Initial events: `claim_success` (monarch, region outcode, points, isFirstOfDay), `claim_failed_quiz`, `nearby_viewed`, `compass_viewed`, `friend_added`, `leaderboard_viewed`, `james_line_shown`, `streak_broken`, `signup_complete`.

Typed wrapper `lib/services/analytics_service.dart`. Strict param validation. Privacy: no PII, no exact coordinates (use outcode); opt-out toggle in settings.

BigQuery: enable linked dataset in console. Add `views/` directory with SQL for common slices (DAU, funnel, claim density by region); document each view in `docs/analytics/`. Ship event wrapper first, enable BigQuery export when there's at least one view ready.

### A/B testing onboarding and UX experiments  (was #94)

Firebase A/B Testing on top of Remote Config conditions (depends on the v1.3 Remote Config work and the v2.0 Analytics work landing first).

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

### Churn-risk retention push via BigQuery ML  (was #97)

Depends on the v2.0 Analytics + BigQuery export. Firebase Predictions is deprecated. Modern path: train a BQ-ML logistic regression on the Analytics export.

Features: `daysSinceLastClaim`, `totalClaims`, `friendsCount`, `streakLength`, `sessionsLast7d`. Label: "did not return in next 7 days". Daily scheduled query writes predictions to GCS; Cloud Function `sendChurnPushes` reads predictions, filters `risk > 0.7 AND notificationPrefs.retentionEnabled`, sends one FCM per user per 7-day window.

Message: James-voiced and specific. "Your streak's looking lonely without you, squire. A VR box in BS6 is waiting." Quiet hours and per-week frequency caps.

Roll out the BQ model with monitoring only first; review prediction quality manually against actual return behaviour for 2 weeks; enable pushes to 10 % first.

---

## Done

- **#117** — Postbox-data problem reporting, admin review & OSM corrections.
- **#121** — Walk-to-destination route mode with corridor + detour scoring.

## Open exploration (no release commitment)

- **#120** — Android XR scaffold (draft). Exploratory; revisit when Jetpack XR artefacts are out of alpha. Close after 6 months untouched.

---

## How to use this doc

1. When starting a v-numbered release, copy its **Ship gate** into the release PR's body so it's the merge checklist.
2. Promote one item at a time from Queued → In flight on a feature branch named `feat/<area>` or `chore/<area>`.
3. Update this file's status when work begins (`Queued` → `In flight`) and again when shipped (move into the matching version's **Done** sub-list, or to the top-level Done list with the merged PR link).
4. Keep entries flat. Deep design detail lives in the PR body, not here.
