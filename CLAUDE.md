# Postbox Game – project context (CLAUDE.md)

## Project summary

Cross-platform (Flutter) mobile app + Firebase (Auth, Firestore, Cloud Functions, Crashlytics, Performance, Analytics, Storage). Core loop: find nearby postboxes (UK, monarch-era rarity), claim once per day for points; rarer = more points. Postbox data is sourced from **OpenStreetMap** (e.g. Overpass API); **test.json** is a sample of that data; the data is ingested and stored in the **cloud database** (Firestore) for the app to use. A **fuzzy compass** hints at where claimed vs unclaimed postboxes are (e.g. by rough direction), without precise locations, to encourage exploration. **Login is required before play**—users must sign in (e.g. Google / email) before accessing the main game. **Friends and leaderboards**: users can add friends and compete on **daily**, **weekly**, **monthly**, and **lifetime** leaderboards. **Problem reporting**: users can report missing postboxes (from the Claim/Nearby empty state) and wrong/missing cyphers (from their claim history), optionally attaching geotagged photos; designated admins review reports in-app, and accepting one updates Firestore, retroactively re-scores affected claims/leaderboards, and generates an OSM changeset. The in-app character **Postman James** introduces the game on first launch and acts as a persistent advisor (Theme Park–style) at the bottom of the screen, commenting on the user's actions with light British humour.

## Postman James (character)

- **Role**: Onboarding (first launch) and in-app advisor throughout the app.
- **Placement**: Introduces the concept on first launch; appears in a strip/panel at the **bottom of the screen** on other screens, commenting on what the user is doing.
- **Tone**: Light, British humour (like the advisor in Theme Park).
- **Current state**: James is rendered by `lib/postman_james_svg.dart` (`PostmanJamesSvg`) using the `assets/postman_james.svg` asset with animated overlays (head-bob, mouth open/close, blink, star-eyes). The persistent James strip (`lib/james_strip.dart`) slides up at the bottom of all main screens via `JamesController` / `JamesControllerScope` in `home.dart`. Messages are centralised in `lib/james_messages.dart`. Idle non-sequiturs fire every 2–5 minutes.

## Login before play

Auth gate is fully implemented. `lib/main.dart` → `Unauthenticated` → `_UnauthGate` (shows `Intro` on first run, then `LoginScreen`); `Authenticated` → `Home`. Login screen (`lib/login/`) supports email/password and Google; registration in `lib/register/`. Both have specific `FirebaseAuthException` error messages (not generic "Login Failure"), a loading overlay on submit, and a password visibility toggle. `LoginButton` is a `FilledButton`; `GoogleLoginButton` is an `OutlinedButton.icon`.

## Friends and leaderboards

Both screens are implemented and accessible from the `NavigationBar` in `Home`.

- **Friends** (`lib/friends_screen.dart`): add by UID (`users/{uid}/friends` array in Firestore), shows "Your UID" copy banner, friend cards with `CircleAvatar` initials. Email lookup not yet implemented — UID only. Tapping a friend card opens `UserProfilePage` (`lib/user_profile_page.dart`) showing their stats and leaderboard rankings.
- **Leaderboard** (`lib/leaderboard_screen.dart`): Daily/Weekly/Monthly/Lifetime tabs reading `leaderboards/{period}/entries`. Top-3 trophy icons, current user's row highlighted. Friends-only toggle filters to `_FriendsPeriodList` (batched `whereIn` queries, groups of 30). Lifetime sort: `uniquePostboxesClaimed` desc, then `totalPoints` desc. Backend writes `{uid, displayName, points}` entries (period) and `{uid, displayName, uniquePostboxesClaimed, totalPoints}` (lifetime); no in-app aggregation.

Display names are stored by the `onUserCreated` Cloud Function in `users/{uid}.displayName` and resolved client-side in the friends list via `FutureBuilder` (with a name cache). This is fully implemented.

## Fuzzy compass

The app shows a **fuzzy compass** that gives the user an **indication** of where **claimed** and **unclaimed** postboxes are nearby (e.g. rough direction or "something in that direction"), **without** giving precise directions or exact locations. Goal: encourage exploration rather than turn-by-turn navigation. Implementation: `lib/fuzzy_compass.dart` — `to8Sectors(counts)` merges 16-wind into 8-wind sectors, `vagueLabel(count)` returns None/One/A few/Several. `_FuzzyCompassPainter` draws claimed sectors grey and unclaimed sectors red, with a North marker. `claimedCompassCounts` and `unclaimedCompassCounts` are returned by the `nearbyPostboxes` Cloud Function. Avoid showing exact bearings or distances that would allow pinpointing.

## Route Mode

A player-facing flow ("Walk to a destination" on the Nearby tab) that lets the user pick a destination and walk to it, claiming en-route postboxes along the way. The destination is shown **precisely** (the user picked it); postboxes stay **fuzzy** (same applyUserClaims contract as Nearby — server strips `geopoint`/`geohash` before sending). Flow lives under `lib/route/`:

- `route_session.dart`: a mutable session holder — start, destination, mode (corridor|detour), corridor metres (50–500), detour minutes (0–60), pace (walk 4.5 km/h or jog 8.5 km/h), and the most recent `routePostboxes` response.
- `destination_picker_screen.dart`: tap-on-map (via `PostboxMap.onTap`) AND a Nominatim search bar backed by `nominatim_service.dart` (UK-biased, 1 req/sec throttle, mandatory `User-Agent`).
- `route_preview_screen.dart`: pace `SegmentedButton`, corridor slider, extra-time slider (>0 switches mode to detour), debounced `routePostboxes` call, "X postboxes worth Y points" headline, "Start route" CTA.
- `live_route_screen.dart`: streaming GPS via `LocationService.positionStream()`, precise destination distance + bearing arrow + ETA at pace, fuzzy compass rotated to face the destination bearing (`route_compass_view.dart`), passive ambient layout. "Where now, postie?" button picks the highest-count fuzzy sector relative to the destination heading and fires a hint via James (player addresses James as "postie", James never refers to himself that way). Periodic `nearbyPostboxes` scan (≥12s OR ≥20m moved); when a returned box has `distance ≤ claimRadius && !claimedToday`, the reusable `ClaimQuizSheet` (extracted from `lib/claim.dart` into `lib/widgets/claim_quiz_sheet.dart`) is shown as a `compact:true` modal bottom sheet — same callables, same quiz, same anti-cheat path. 60s dedupe so the same postbox doesn't re-prompt after dismissal. On arrival (distance < 25 m), fires a local notification via `route_notifications.dart` (wraps `flutter_local_notifications`) then `pushReplacement`s to `route_completion_screen.dart`.
- Backend callable `routePostboxes` (`functions/src/routePostboxes.ts`) takes start/dest + mode + corridor or detour params, fetches via the same 9-cell geohash prefix pattern as `_lookupPostboxes.ts`, filters out the user's claimed-today set, then either sums `pointsForMonarch` over the corridor (`filterToCorridor` in `_routePlanner.ts`) OR runs the orienteering `beamSearchOrienteering` over the time ellipse (`filterToEllipse`). Returns ONLY `{ count, points, directDistanceM, budgetDistanceM, warnings }` — never postbox IDs, coords, or per-monarch breakdowns. 30 km destination cap.
- Shared algorithm module `functions/src/_routePlanner.ts` is reused by both the new callable and the internal CLI `functions/src/scripts/plan_route.ts` (single source of truth for the routing maths).

## Problem reporting, admin review & OSM corrections

Fully implemented end-to-end.

- **Reporting (Flutter, `lib/reports/`)**: `report_repository.dart` picks photos (camera/gallery via `image_picker`, `requestFullMetadata: true`), extracts EXIF GPS + capture time (`exif` package), uploads to Cloud Storage under `report_photos/{uid}/`, then calls the `submitReport` Cloud Function. `report_missing_postbox_screen.dart` (reached from the Claim and Nearby empty states; pre-filled with the scan position when available) captures the user's live GPS as the authoritative location plus an optional note, suggested cypher, and ≤3 photos. `report_cypher_screen.dart` (reached from the History detail sheet) reports a wrong/missing cypher on a claimed box. `report_form_widgets.dart` has the shared `CypherPicker` (known cyphers + "Plain / no cypher" + "I'm not sure") and `PhotoPickerField`. `my_reports_screen.dart` (AppBar overflow → "My reports") lists the user's own reports with status chips. EXIF GPS is best-effort (browsers strip it; iOS keeps it only with `requestFullMetadata` + camera location on) — the live `geolocator` fix is always authoritative; photo EXIF is supplementary verification data for reviewers.
- **Admin (Flutter, `lib/admin/`)**: `admin_access.dart` (`AdminAccess.isAdmin()`) reads the Firebase Auth `admin` custom claim (cached, force-refreshable). `admin_reports_screen.dart` (AppBar overflow → "Admin · Reports", shown only when the claim is present) has Pending/Accepted/Rejected tabs streaming the `reports` collection; cards show location (with a "Map" link), current vs suggested cypher, note, and photo thumbnails (tap → full view with the photo's EXIF GPS vs the reported location); Accept (with a final-cypher picker + ref/note) and Reject actions call `reviewReport`; the accept dialog surfaces the OSM editor deep-link, the generated `.osc` Storage path, and re-score counts. Grant admin with `node functions/set_admin.js <uid> --project the-postbox-game [--remove]` (the user must re-authenticate afterwards).
- **Backend (`functions/src/reports.ts`)**: `submitReport` (callable, auth required) validates type/coords/cypher (whitelisted against `KNOWN_MONARCHS` in `_getPoints.ts`)/note (profanity-filtered)/photos (paths must sit under `report_photos/{uid}/`, blobs must exist in Storage), enforces a per-user cap of `MAX_REPORTS_PER_DAY` (10) accepted reports per London day via a transactional counter at `reportQuotas/{uid}` (`nextQuotaState` is a pure, unit-tested helper; `resource-exhausted` when exceeded), and writes `reports/{id}` with `status: 'pending'`. `reviewReport` (callable, gated on `request.auth.token.admin === true`, `timeoutSeconds: 300`) on reject just stamps the doc; on accept it updates `postbox/{id}` (or creates `postbox/manual_{reportId}` with `source: 'user_report'` for a missing box), runs the retroactive rescore, fetches the OSM node and writes an `osmChange` `.osc` to `osm_changesets/{reportId}.osc`, and returns the editor deep-link + `{ rescoredClaims, affectedUsers }`. `buildOsmChange` is a pure, unit-tested helper. OSM submission is deliberately **not** automated (OSM automated-edit policy) — a human uploads the generated `.osc` / uses the iD deep-link.
- **Retroactive rescoring (`functions/src/_recomputeScores.ts`)**: when an accepted cypher change alters a box's points, `repointClaimsForPostbox` rewrites every claim's `points`/`monarch` in batches (with `correctedAt`/`correctedFromMonarch`/`correctedFromPoints` audit fields), then `recomputeUserAggregates` re-derives each affected user's `lifetimePoints`/`uniquePostboxesClaimed`/`maxDailyPoints` from claims, re-sums daily/weekly/monthly via `updateUserLeaderboards`, refreshes `leaderboards/lifetime`, and adjusts the box's-county `users/{uid}/countyStats/{slug}` + `leaderboards/lifetime_by_county/counties/{slug}`. Runs inline in `reviewReport` (bounded by a box's distinct claimants). Streaks are not recomputed (they depend on claim dates, not points).
- **Rules**: `firestore.rules` — `reports/{id}` readable by the reporter or an admin (`request.auth.token.admin`), no client writes (server-only via the two callables). `storage.rules` (new file, registered in `firebase.json`) — `report_photos/{uid}/{file}` owner-write + owner/admin-read (≤10 MB, images only); `osm_changesets/{file}` admin-read-only, server-write only.

## Key paths

- **App entry**: `lib/main.dart` → **if unauthenticated** → `_UnauthGate` → `Intro` (first run) or `LoginScreen`; **if authenticated** → `Home`. `Home` (`lib/home.dart`) is a `NavigationBar` + `IndexedStack` shell: tabs are **Nearby** (index 0), **Claim** (index 1), **Leaderboard** (index 2), **Friends** (index 3), **History** (index 4 — `ClaimHistoryScreen`, map/list `ViewToggle`). The AppBar `PopupMenuButton` has My reports, Admin · Reports (admins only), Settings, How to play. Named routes `/nearby`, `/claim`, `/friends`, `/leaderboard`, `/history`, `/settings` are retained for deep-link use (each wrapped in an auth guard).
- **Backend**: `functions/src/index.ts` exports `nearbyPostboxes`, `startScoring`, `updateDisplayName`, `onUserCreated`, `newDayScoreboard`, `registerFcmToken`, `onFriendAdded`, `userClaimHistory`, `submitReport`, `reviewReport`, `routePostboxes`. Helper modules: `_lookupPostboxes.ts` (ngeohash + Firestore geohash prefix queries), `_getPoints.ts` (monarch → points: EIIR=2, GR/GVR/GVIR/SCOTTISH_CROWN=4, VR=7, EVIIR/CIIIR=9, EVIIIR=12; also `KNOWN_MONARCHS`, `pointsForMonarch`), `_leaderboardUtils.ts` (period key staleness, merge/sort helpers), `_nearbyUtils.ts` (`applyUserClaims` for per-user claim state), `_streakUtils.ts` (`computeNewStreak`), `_notifications.ts` (FCM send, notification eligibility helpers), `_recomputeScores.ts` (retroactive re-scoring after a cypher correction), `_routePlanner.ts` (pure orienteering + corridor filters + beam search; reused by `routePostboxes` and the `scripts/plan_route.ts` CLI). `reports.ts` holds the two report callables + the pure helpers `buildOsmChange`, `parsePhotos`, `nextQuotaState`. `functions/set_admin.js` is a CLI to grant/revoke the `admin` custom claim. Friends list in `users/{uid}/friends` array; leaderboards updated by Cloud Functions in `leaderboards/{daily|weekly|monthly|lifetime}` documents. `reports/{id}` holds user-submitted data-problem reports (server-write only); `reportQuotas/{uid}` is the per-user daily submit-rate counter (server-only, never client-read). `fcmTokens/{uid}` stores FCM tokens (separate collection — not exposed via world-readable `users/{uid}` rules). `newDayScoreboard` scheduled at midnight London time; resets daily scores, rebuilds weekly/monthly from claims.
- **Postbox data source and storage**: Postbox data is **sourced from OpenStreetMap (OSM)**—e.g. Overpass API (`amenity=post_box`, UK area). **test.json** in the repo is a sample of the OSM/Overpass response: nodes with `type`, `id`, `lat`, `lon`, and `tags` (e.g. `amenity`, `ref`, `royal_cypher`, `post_box:type`, `collection_times`, `postal_code`). This data is **not** queried from OSM at app runtime; it is **ingested and stored in the cloud database** (Firestore). The app and existing Cloud Functions read from Firestore only.
- **OSM→Firestore import pipeline**: Implemented in `functions/import_postboxes.js` (the single canonical importer — no `scripts/` duplicate). Run from the `functions/` directory: `node import_postboxes.js <overpass-export.json> --project the-postbox-game`. Stores each postbox as `{ geohash (precision 9), geopoint, overpass_id, monarch?, reference?, county? }` in `postbox/{osm_<id>}` with batch writes of 400. **Incremental by default**: subsequent runs only write nodes whose post-validation fields (geohash, lat/lon, monarch, reference, county) have changed since the previous run, tracked via a SHA-256 manifest at `functions/.last_import_manifest.json` (gitignored). Flags: `--dry-run` (scan & report counts without writing), `--prune` (soft-mark `osm_*` docs whose OSM node disappeared via `removedFromOsm: true` + `removedFromOsmAt` — never hard-deletes; re-appearance auto-clears because every normal write delete()s the flag), `--manifest <path>` (override), `--no-manifest` (force full re-import), `--overwrite-corrections` (re-import over `correctedBy` docs). GEOHASH_PRECISION must remain 9 (maximum) so stored hashes match precision-8 prefix queries used by the 30 m claim scan. Postboxes added from accepted "missing postbox" reports live at `postbox/manual_{reportId}` with `source: 'user_report'`, `reportId`, and the same geohash/geopoint schema; an accepted cypher correction also adds `correctedBy`/`correctedAt` (and a future OSM re-import of the now-added node would need dedup against `manual_*` docs — not yet built). New Flutter deps for reporting: `firebase_storage`, `image_picker`, `exif`, `url_launcher`.
- **Auth**: `UserRepository` + `AuthenticationBloc`; Google Sign-In + Email/Password; `firebase_options.dart` has Android, iOS, macOS, Web, and Windows configurations (generated by FlutterFire CLI).

## Critical issues

- **Functions**: (Fixed) Geohash logic uses **ngeohash** (replacing geofirex). Firestore uses **`database.collection('postboxes')`** and **`database.collection('claims').add(data)`**. **index.js** initializes admin with `if (!admin.apps.length) admin.initializeApp();` before requiring other modules.
- **Flutter SDK**: (Fixed) `pubspec.yaml` `sdk: ">=3.0.0 <4.0.0"`. Dart 3 compatible.
- **Bloc**: (Fixed) All blocs use constructor-based `on<Event>` API (Bloc 8.x).
- **Geolocator**: App uses `desiredAccuracy: LocationAccuracy.high` (geolocator ^10). In geolocator 13+ prefer `locationSettings: LocationSettings(accuracy: LocationAccuracy.high)`.
- **Flutter Compass**: Code uses `FlutterCompass.events?.listen(...)` and `mounted` check for null safety. Package is lightly maintained; alternative: `sensors_plus` (magnetometer) with custom heading calculation.
- **Android**: Root `android/build.gradle` uses **jcenter()** (deprecated/removed). **compileSdkVersion 33**, **targetSdkVersion 30** — Play Store may require higher target. Kotlin plugin version needs updating (Flutter now prompts: update `org.jetbrains.kotlin.android` in `android/settings.gradle`). Debug builds fail with Java heap space — use `--release` or increase Gradle JVM heap.
- **iOS**: No `Podfile` in repo (Flutter regenerates on `pod install`). `firebase_options.dart` now has iOS config (FlutterFire CLI has been run). A `Podfile` will be needed when building for iOS. `Info.plist` has `NSLocation*`, `NSCameraUsageDescription`, and `NSPhotoLibraryUsageDescription` strings (the last two added for report photo attachments).
- **firebase_dynamic_links**: Removed (Firebase deprecated Dynamic Links Aug 2025; was unused in lib).
- **Intro / Postman James assets**: (Fixed) `flare_flutter` / `james.flr` removed. James is `PostmanJamesSvg` in `lib/postman_james_svg.dart` using `assets/postman_james.svg`. No custom font needed — `google_fonts` provides Plus Jakarta Sans and Playfair Display.
- **Claim screen**: (Fixed) Full `initial/searching/results/empty/quiz/quizFailed/claimed` state machine. `startScoring` Cloud Function implemented with per-user claim tracking, streak updates, and leaderboard aggregation.
- **Theme**: (Fixed) Centralized in `lib/theme.dart` (`AppTheme.light/dark`, `AppSpacing`). Postal red `#C8102E` is primary; gold `#FFB400` is accent; royal navy `#0A1931` is dark. Light and dark themes both configured.
- **`flutter_lints`**: Added to dev_dependencies (`flutter_lints: ^6.0.0`). `flutter analyze` reports no issues.

## Tests

- `test/widget_test.dart` uses `firebase_auth_mocks` + `fake_cloud_firestore` and `setupFirebaseCoreMocks()` — tests run without real Firebase. 105 Dart tests passing.
- `functions/src/test/test.index.ts` uses `firebase-functions-test`. 279 TypeScript tests passing (pure unit tests + auth/validation integration tests that gracefully skip when no emulator is running). Includes tests for `updateFcmTokens`, `diffFriends`, `shouldNotifyFirstClaim`, `shouldNotifyOvertake`, `buildOsmChange`, `parsePhotos`, `nextQuotaState`, `pointsForMonarch`, `maxDailyFromClaims`, `repointClaimsForPostbox` (mock Firestore), and `submitReport`/`reviewReport` auth & validation.

## Security / release

`firebase_options.dart` and test file reference project ID **the-postbox-game** and service account path; ensure no secrets in repo for store release. Use environment/config for CI and store builds.

---

## Post-build review (suggestions only)

Web build succeeds (`flutter build web`). Android debug build fails with Java heap space (pre-existing Gradle/JVM issue); release build blocked by Kotlin plugin version. The following are **suggestions only** for follow-up work.

### Next steps (prioritised)

1. **Android build**: Update Kotlin plugin in `android/settings.gradle` to latest stable. Bump `compileSdkVersion`/`targetSdkVersion` to 34+ for Play Store. Debug builds fail with Java heap space — use `--release` or increase Gradle JVM heap.
2. **iOS build**: A `Podfile` will be needed (`pod install` in the `ios/` directory). Firebase options are already configured.
3. **Rate limiting / App Check enforcement**: App Check is configured with `AndroidPlayIntegrityProvider` for release builds — ensure it is enforced in the Firebase Console.
4. **Friend challenges / social features**: Friend profile pages (`UserProfilePage`) and friends-only leaderboard filtering are implemented. Friend challenges (e.g. direct head-to-head invites) are not yet implemented.
5. **Push notifications (social)**: Friend-first-claim, overtake, and friend-added FCM notifications are implemented. Gameplay notifications (daily reminder, streak break, rare postbox nearby) are not yet implemented.

**Already done** (items from prior list that are now complete):
- `startScoring` Cloud Function (with per-user claims, streaks, leaderboard updates)
- Display names stored in Firestore (`onUserCreated` + `updateDisplayName`)
- Postman James SVG strip on all main screens with idle non-sequiturs
- OSM→Firestore import script (`functions/import_postboxes.js`)
- Firebase/Flutter test mocks (67 Dart tests, 198 TS tests, all passing)
- iOS `firebase_options.dart` configured via FlutterFire CLI
- Staggered animations, confetti, pull-to-refresh all implemented
- FCM push notifications for social events: friend's first claim of the day, overtake, added as friend (`_notifications.ts`, `registerFcmToken`, `onFriendAdded`)
- Lifetime leaderboard tab (unique boxes + total points, sorted by unique boxes)
- Friends-only leaderboard toggle (`_FriendsPeriodList` with batched `whereIn` queries)
- `UserProfilePage` — friend/own profile with stats and 4-period leaderboard rankings
- Android home-screen widget (`HomeWidgetService`, deep-link auto-scan on tap)
- Wear OS companion (`lib/main_wear.dart`, `lib/wear/` — simplified scan→quiz→claim flow + a full-screen fuzzy compass; `lib/wear/wear_theme.dart`)
- Android Auto integration (`android/app/src/phone/kotlin/com/code418/postbox_game/car/` — `PostboxCarAppService`, `HomeCarScreen` quick-claim, `LeaderboardCarScreen`, `StatsRepository` reads Firestore directly since the car runtime never loads the Dart engine; `phone` product flavour only)
- OSM tile zoom hard-capped at 17 in `PostboxMap` (hides postbox POI icons at ≥18)
- `newDayScoreboard` scheduled Cloud Function — midnight London rollover, weekly/monthly rebuild
- Postbox-data problem reporting: `submitReport`/`reviewReport` callables, `reports` collection, geotagged-photo upload to Cloud Storage (`report_photos/`), in-app admin review UI gated on the `admin` custom claim (`set_admin.js`), retroactive re-scoring of claims/leaderboards on cypher corrections (`_recomputeScores.ts`), and osmChange `.osc` generation + iD deep-links for OSM follow-up (`buildOsmChange`, `osm_changesets/`)

### Potential security concerns

- **Firestore rules**: (Done) `firestore.rules` restricts all writes — postboxes/claims/leaderboards/reports are server-only; `users/{uid}` client writes restricted to `friends` array, `notificationPrefs` map, and `mapColor` string only. `fcmTokens/{uid}` is server-write only (client read by owner only). `reports/{id}` readable by the reporter or an `admin`-claim user only.
- **Storage rules**: (Done) `storage.rules` — `report_photos/{uid}/{file}` writable only by that user (≤10 MB, images only), readable by the owner or an admin; `osm_changesets/{file}` admin-read-only, server-write only; everything else closed.
- **Cloud Functions**: (Done) All callables enforce `request.auth?.uid` (and `reviewReport` requires the `admin` custom claim) and validate inputs (lat/lng ranges, meters bounds, name/note length, profanity, cypher whitelist, photo path/count).
- **Secrets**: No API keys or service account JSON paths in the repo; use env/config and secure storage for release builds.
- **Rate limiting / abuse**: `submitReport` has a per-uid daily cap (`reportQuotas/{uid}`, `MAX_REPORTS_PER_DAY`); `startScoring` has a travel-speed anti-spoof check. Still consider rate limits on the other callables and broader abuse detection for claims (e.g. same device, location spoofing).
- **PII**: Limit PII in claims and leaderboard display (e.g. display names only); comply with privacy policy and data deletion requests.

### Added features to encourage engagement

- Streaks for daily claims; achievements/badges.
- “Postbox of the day” or rare-find highlights; push reminders.
- Friend challenges; seasonal or regional leaderboards.
- Sharing a claim to social; Postman James unlockable lines or reactions.
- Light narrative or collectible angle tied to monarch eras.
