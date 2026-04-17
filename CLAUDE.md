# Postbox Game – project context (CLAUDE.md)

## Project summary

Cross-platform (Flutter) mobile app + Firebase (Auth, Firestore, Cloud Functions, Crashlytics, Performance, Analytics, Storage). Core loop: find nearby postboxes (UK, monarch-era rarity), claim once per day for points; rarer = more points. Postbox data is sourced from **OpenStreetMap** (e.g. Overpass API); **test.json** is a sample of that data; the data is ingested and stored in the **cloud database** (Firestore) for the app to use. A **fuzzy compass** hints at where claimed vs unclaimed postboxes are (e.g. by rough direction), without precise locations, to encourage exploration. **Login is required before play**—users must sign in (e.g. Google / email) before accessing the main game. **Friends and leaderboards**: users can add friends and compete on **daily**, **weekly**, **monthly**, and **lifetime** leaderboards. The in-app character **Postman James** introduces the game on first launch and acts as a persistent advisor (Theme Park–style) at the bottom of the screen, commenting on the user's actions with light British humour.

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

## Key paths

- **App entry**: `lib/main.dart` → **if unauthenticated** → `_UnauthGate` → `Intro` (first run) or `LoginScreen`; **if authenticated** → `Home`. `Home` (`lib/home.dart`) is a `NavigationBar` + `IndexedStack` shell: tabs are **Nearby** (index 0), **Claim** (index 1), **Leaderboard** (index 2), **Friends** (index 3). Settings is in an AppBar `PopupMenuButton`. Named routes `/nearby`, `/claim`, `/friends`, `/leaderboard`, `/settings` are retained for deep-link use.
- **Backend**: `functions/src/index.ts` exports `nearbyPostboxes`, `startScoring`, `updateDisplayName`, `onUserCreated`, `newDayScoreboard`, `registerFcmToken`, `onFriendAdded`. Helper modules: `_lookupPostboxes.ts` (ngeohash + Firestore geohash prefix queries), `_getPoints.ts` (monarch → points: EIIR=2, GR/GVR/GVIR/SCOTTISH_CROWN=4, VR=7, EVIIR/CIIIR=9, EVIIIR=12), `_leaderboardUtils.ts` (period key staleness, merge/sort helpers), `_nearbyUtils.ts` (`applyUserClaims` for per-user claim state), `_streakUtils.ts` (`computeNewStreak`), `_notifications.ts` (FCM send, notification eligibility helpers). Friends list in `users/{uid}/friends` array; leaderboards updated by Cloud Functions in `leaderboards/{daily|weekly|monthly|lifetime}` documents. `fcmTokens/{uid}` stores FCM tokens (separate collection — not exposed via world-readable `users/{uid}` rules). `newDayScoreboard` scheduled at midnight London time; resets daily scores, rebuilds weekly/monthly from claims.
- **Postbox data source and storage**: Postbox data is **sourced from OpenStreetMap (OSM)**—e.g. Overpass API (`amenity=post_box`, UK area). **test.json** in the repo is a sample of the OSM/Overpass response: nodes with `type`, `id`, `lat`, `lon`, and `tags` (e.g. `amenity`, `ref`, `royal_cypher`, `post_box:type`, `collection_times`, `postal_code`). This data is **not** queried from OSM at app runtime; it is **ingested and stored in the cloud database** (Firestore). The app and existing Cloud Functions read from Firestore only.
- **OSM→Firestore import pipeline**: Implemented in `functions/import_postboxes.js`. Run from the `functions/` directory: `node import_postboxes.js <overpass-export.json> --project the-postbox-game`. Stores each postbox as `{ geohash (precision 9), geopoint, overpass_id, monarch?, reference? }` in `postbox/{osm_<id>}` with batch writes of 400. Use `--dry-run --limit 5` to preview. GEOHASH_PRECISION must remain 9 (maximum) so stored hashes match precision-8 prefix queries used by the 30 m claim scan.
- **Auth**: `UserRepository` + `AuthenticationBloc`; Google Sign-In + Email/Password; `firebase_options.dart` has Android, iOS, macOS, Web, and Windows configurations (generated by FlutterFire CLI).

## Critical issues

- **Functions**: (Fixed) Geohash logic uses **ngeohash** (replacing geofirex). Firestore uses **`database.collection('postboxes')`** and **`database.collection('claims').add(data)`**. **index.js** initializes admin with `if (!admin.apps.length) admin.initializeApp();` before requiring other modules.
- **Flutter SDK**: (Fixed) `pubspec.yaml` `sdk: ">=3.0.0 <4.0.0"`. Dart 3 compatible.
- **Bloc**: (Fixed) All blocs use constructor-based `on<Event>` API (Bloc 8.x).
- **Geolocator**: App uses `desiredAccuracy: LocationAccuracy.high` (geolocator ^10). In geolocator 13+ prefer `locationSettings: LocationSettings(accuracy: LocationAccuracy.high)`.
- **Flutter Compass**: Code uses `FlutterCompass.events?.listen(...)` and `mounted` check for null safety. Package is lightly maintained; alternative: `sensors_plus` (magnetometer) with custom heading calculation.
- **Android**: Root `android/build.gradle` uses **jcenter()** (deprecated/removed). **compileSdkVersion 33**, **targetSdkVersion 30** — Play Store may require higher target. Kotlin plugin version needs updating (Flutter now prompts: update `org.jetbrains.kotlin.android` in `android/settings.gradle`). Debug builds fail with Java heap space — use `--release` or increase Gradle JVM heap.
- **iOS**: No `Podfile` in repo (Flutter regenerates on `pod install`). `firebase_options.dart` now has iOS config (FlutterFire CLI has been run). A `Podfile` will be needed when building for iOS.
- **firebase_dynamic_links**: Removed (Firebase deprecated Dynamic Links Aug 2025; was unused in lib).
- **Intro / Postman James assets**: (Fixed) `flare_flutter` / `james.flr` removed. James is `PostmanJamesSvg` in `lib/postman_james_svg.dart` using `assets/postman_james.svg`. No custom font needed — `google_fonts` provides Plus Jakarta Sans and Playfair Display.
- **Claim screen**: (Fixed) Full `initial/searching/results/empty/quiz/quizFailed/claimed` state machine. `startScoring` Cloud Function implemented with per-user claim tracking, streak updates, and leaderboard aggregation.
- **Theme**: (Fixed) Centralized in `lib/theme.dart` (`AppTheme.light/dark`, `AppSpacing`). Postal red `#C8102E` is primary; gold `#FFB400` is accent; royal navy `#0A1931` is dark. Light and dark themes both configured.
- **`flutter_lints`**: Added to dev_dependencies (`flutter_lints: ^6.0.0`). `flutter analyze` reports no issues.

## Tests

- `test/widget_test.dart` uses `firebase_auth_mocks` + `fake_cloud_firestore` and `setupFirebaseCoreMocks()` — tests run without real Firebase. 67 Dart tests passing.
- `functions/src/test/test.index.ts` uses `firebase-functions-test`. 198 TypeScript tests passing (pure unit tests + auth/validation integration tests that gracefully skip when no emulator is running). Includes tests for `updateFcmTokens`, `diffFriends`, `shouldNotifyFirstClaim`, `shouldNotifyOvertake`.

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
- OSM tile zoom hard-capped at 17 in `PostboxMap` (hides postbox POI icons at ≥18)
- `newDayScoreboard` scheduled Cloud Function — midnight London rollover, weekly/monthly rebuild

### Potential security concerns

- **Firestore rules**: (Done) `firestore.rules` restricts all writes — postboxes/claims/leaderboards are server-only; `users/{uid}` client writes restricted to `friends` array and `notificationPrefs` map only. `fcmTokens/{uid}` is server-write only (client read by owner only).
- **Cloud Functions**: (Done) All callables enforce `request.auth?.uid` and validate inputs (lat/lng ranges, meters bounds, name length/profanity).
- **Secrets**: No API keys or service account JSON paths in the repo; use env/config and secure storage for release builds.
- **Rate limiting / abuse**: Consider rate limits on callables and abuse detection for claims (e.g. same device, location spoofing).
- **PII**: Limit PII in claims and leaderboard display (e.g. display names only); comply with privacy policy and data deletion requests.

### Added features to encourage engagement

- Streaks for daily claims; achievements/badges.
- “Postbox of the day” or rare-find highlights; push reminders.
- Friend challenges; seasonal or regional leaderboards.
- Sharing a claim to social; Postman James unlockable lines or reactions.
- Light narrative or collectible angle tied to monarch eras.
