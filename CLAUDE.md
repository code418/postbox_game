# Postbox Game – project context (CLAUDE.md)

## Project summary

Cross-platform (Flutter) mobile app + Firebase (Auth, Firestore, Cloud Functions, Crashlytics, Performance, Analytics, Storage). Core loop: find nearby postboxes (UK, monarch-era rarity), claim once per day for points; rarer = more points. Postbox data is sourced from **OpenStreetMap** (e.g. Overpass API); **test.json** is a sample of that data; the data is ingested and stored in the **cloud database** (Firestore) for the app to use. A **fuzzy compass** hints at where claimed vs unclaimed postboxes are (e.g. by rough direction), without precise locations, to encourage exploration. **Login is required before play**—users must sign in (e.g. Google / email) before accessing the main game. **Friends and leaderboards**: users can add friends and compete on **daily**, **weekly**, and **monthly** leaderboards. The in-app character **Postman James** introduces the game on first launch and acts as a persistent advisor (Theme Park–style) at the bottom of the screen, commenting on the user's actions with light British humour.

## Postman James (character)

- **Role**: Onboarding (first launch) and in-app advisor throughout the app.
- **Placement**: Introduces the concept on first launch; appears in a strip/panel at the **bottom of the screen** on other screens, commenting on what the user is doing.
- **Tone**: Light, British humour (like the advisor in Theme Park).
- **Current state**: `lib/intro.dart` now renders James as a **CustomPainter** (`_JamesPainter`) — navy body, red cap, skin-tone face, dot eyes or star-eyes (`showStarEyes: true`). No external asset; no flare_flutter dependency. The persistent "James at bottom commenting on actions" is not yet on all main screens — a `JamesHint` widget (small James + speech bubble) is planned but not yet placed on Nearby/Claim.

## Login before play

Auth gate is fully implemented. `lib/main.dart` → `Unauthenticated` → `_UnauthGate` (shows `Intro` on first run, then `LoginScreen`); `Authenticated` → `Home`. Login screen (`lib/login/`) supports email/password and Google; registration in `lib/register/`. Both have specific `FirebaseAuthException` error messages (not generic "Login Failure"), a loading overlay on submit, and a password visibility toggle. `LoginButton` is a `FilledButton`; `GoogleLoginButton` is an `OutlinedButton.icon`.

## Friends and leaderboards

Both screens are implemented and accessible from the `NavigationBar` in `Home`.

- **Friends** (`lib/friends_screen.dart`): add by UID (`users/{uid}/friends` array in Firestore), shows "Your UID" copy banner, friend cards with `CircleAvatar` initials. Email lookup not yet implemented — UID only.
- **Leaderboard** (`lib/leaderboard_screen.dart`): Daily/Weekly/Monthly tabs reading `leaderboards/{period}/entries`. Top-3 trophy icons, current user's row highlighted. Backend must write `{uid, displayName, points}` entries; no in-app aggregation.

**Remaining**: display names in the friends list require storing `displayName` in `users/{uid}` on registration and resolving it client-side or via a Cloud Function.

## Fuzzy compass

The app shows a **fuzzy compass** that gives the user an **indication** of where **claimed** and **unclaimed** postboxes are nearby (e.g. rough direction or "something in that direction"), **without** giving precise directions or exact locations. Goal: encourage exploration rather than turn-by-turn navigation. Implementation: use existing compass/nearby data (`lib/nearby.dart`, `lib/claim.dart`, `lib/compass.dart`, backend compass/distance data) but present directions in a deliberately imprecise way (e.g. cardinal or 8-wind sectors, optional distance band like "near"/"medium"/"far", and separate indication for claimed vs unclaimed). Avoid showing exact bearings or distances that would allow pinpointing.

## Key paths

- **App entry**: `lib/main.dart` → **if unauthenticated** → `_UnauthGate` → `Intro` (first run) or `LoginScreen`; **if authenticated** → `Home`. `Home` (`lib/home.dart`) is a `NavigationBar` + `IndexedStack` shell: tabs are **Nearby** (index 0), **Claim** (index 1), **Leaderboard** (index 2), **Friends** (index 3). Settings is in an AppBar `PopupMenuButton`. Named routes `/nearby`, `/Claim`, `/friends`, `/leaderboard`, `/settings` are retained for deep-link use.
- **Backend**: `functions/index.js` exports `nearbyPostboxes` and `startScoring`; `_lookupPostboxes.js` uses geohash + Firestore; `_getPoints.js` maps monarch (EIIR, GR, GVR, GVIR, VR, EVIIR, EVIIIR) to points. **New**: friends list and leaderboard data (Firestore: e.g. `users/{uid}/friends`, `leaderboards/daily|weekly|monthly` or aggregated in Cloud Functions).
- **Postbox data source and storage**: Postbox data is **sourced from OpenStreetMap (OSM)**—e.g. Overpass API (`amenity=post_box`, UK area). **test.json** in the repo is a sample of the OSM/Overpass response: nodes with `type`, `id`, `lat`, `lon`, and `tags` (e.g. `amenity`, `ref`, `royal_cypher`, `post_box:type`, `collection_times`, `postal_code`). This data is **not** queried from OSM at app runtime; it is **ingested and stored in the cloud database** (Firestore). The app and existing Cloud Functions read from Firestore only.
- **OSM→Firestore import pipeline (to implement)**: (1) Run Overpass query for UK `amenity=post_box` (see test.json structure). (2) For each node: compute geohash (e.g. ngeohash.encode(lat, lon, 9)), build Firestore document `{ position: { geopoint: GeoPoint(lat, lon), geohash: string }, monarch: tags.royal_cypher || null, ref: tags.ref, ... }`. (3) Batch write to `postboxes` collection (document ID can be OSM node id or a stable hash). (4) Ensure composite index on `postboxes` for `position.geohash` (orderBy/range queries). Can be a one-off script or scheduled Cloud Function.
- **Auth**: `UserRepository` + `AuthenticationBloc`; Google Sign-In + Email/Password; `firebase_options.dart` has **Android and Web** only—**iOS throws**.

## Critical issues

- **Functions**: (Fixed) Geohash logic uses **ngeohash** (replacing geofirex). Firestore uses **`database.collection('postboxes')`** and **`database.collection('claims').add(data)`**. **index.js** initializes admin with `if (!admin.apps.length) admin.initializeApp();` before requiring other modules.
- **Flutter SDK**: (Fixed) `pubspec.yaml` `sdk: ">=3.0.0 <4.0.0"`. Dart 3 compatible.
- **Bloc**: (Fixed) All blocs use constructor-based `on<Event>` API (Bloc 8.x).
- **Geolocator**: App uses `desiredAccuracy: LocationAccuracy.high` (geolocator ^10). In geolocator 13+ prefer `locationSettings: LocationSettings(accuracy: LocationAccuracy.high)`.
- **Flutter Compass**: Code uses `FlutterCompass.events?.listen(...)` and `mounted` check for null safety. Package is lightly maintained; alternative: `sensors_plus` (magnetometer) with custom heading calculation.
- **Android**: Root `android/build.gradle` uses **jcenter()** (deprecated/removed). **compileSdkVersion 33**, **targetSdkVersion 30** — Play Store may require higher target. Kotlin plugin version needs updating (Flutter now prompts: update `org.jetbrains.kotlin.android` in `android/settings.gradle`). Debug builds fail with Java heap space — use `--release` or increase Gradle JVM heap.
- **iOS**: No `Podfile` in repo (Flutter may regenerate). **`firebase_options.dart` throws for iOS** — run FlutterFire CLI to add iOS config if targeting iOS.
- **firebase_dynamic_links**: Removed (Firebase deprecated Dynamic Links Aug 2025; was unused in lib).
- **Intro / Postman James assets**: (Fixed) `flare_flutter` / `james.flr` removed. James is now a `CustomPainter` in `lib/intro.dart`. `james.flr` still listed as an asset in `pubspec.yaml` (harmless; can be removed). No custom font needed — `google_fonts` provides Plus Jakarta Sans and Playfair Display.
- **Claim screen**: (Fixed) Was a dead-end — no actual claim button. Now has full `initial/searching/results/empty/claimed` state machine with a `claimPostbox` Firebase callable and success animation. **Note**: `claimPostbox` callable must be implemented in `functions/index.js` — currently stubbed.
- **Theme**: (Fixed) Centralized in `lib/theme.dart` (`AppTheme.light/dark`, `AppSpacing`). No more ad-hoc inline colours. Postal red `#C8102E` is primary; gold `#FFB400` is accent; royal navy `#0A1931` is dark.
- **`flutter_lints`**: Not in `dev_dependencies` — `analysis_options.yaml` references it but it's absent. Harmless warning; add `flutter_lints: ^4.0.0` to dev_dependencies if lint rules are wanted.

## Tests

- `test/widget_test.dart` pumps `PostboxGame()` which calls `Firebase.initializeApp()` — unit tests need Firebase mocked or test will fail.
- Functions test `test/index.js` expects `nearbyPostboxes(request, res)` but the function is **onCall**, i.e. `(data, context)`; test is wrong and references undefined `projectConfig`.

## Security / release

`firebase_options.dart` and test file reference project ID **the-postbox-game** and service account path; ensure no secrets in repo for store release. Use environment/config for CI and store builds.

---

## Post-build review (suggestions only)

Web build succeeds (`flutter build web`). Android debug build fails with Java heap space (pre-existing Gradle/JVM issue); release build blocked by Kotlin plugin version. The following are **suggestions only** for follow-up work.

### Next steps (prioritised)

1. **`claimPostbox` Cloud Function**: The Claim screen calls a `claimPostbox` Firebase callable that doesn’t exist yet in `functions/index.js`. Implement it: validate auth, check 30m radius, write to `claims` collection, return `{points}`.
2. **Friends display names**: Store `displayName` in Firestore `users/{uid}` on register/login. Friends list currently shows raw UIDs. Resolve to names client-side or via a Cloud Function lookup.
3. **Postman James advisor strips**: Add `JamesHint` widget (small James + speech bubble row) at the bottom of `Nearby` and `Claim` screens with contextual copy. Class designed but not yet placed.
4. **Lottie James** (optional): If an animation asset is commissioned, replace `PostManJames` `CustomPainter` with `Lottie.asset(‘assets/james.json’)` (`lottie: ^3.1.0`).
5. **OSM→Firestore pipeline**: Implement or run the import/sync (Overpass → map to `postboxes` schema → batch write); ensure indexes.
6. **Android build**: Update Kotlin plugin in `android/settings.gradle` to latest stable. Consider bumping `compileSdkVersion`/`targetSdkVersion` to 34 for Play Store.
7. **Tests**: Add Firebase/Flutter mocks so widget tests don’t call real Firebase; fix or run functions tests with the emulator.
8. **iOS**: Run `dart run flutterfire configure` and add iOS to `firebase_options.dart` if targeting iOS.
9. **Phase 4 polish**: Staggered list animations (`flutter_staggered_animations`), confetti on claim success, pull-to-refresh on Nearby, dead code removal (`lib/signin.dart`, `lib/upload.dart`).

### Potential security concerns

- **Firestore rules**: Define who can read/write `postboxes`, `claims`, `users`, `leaderboards`, and friends subcollections; restrict writes to authenticated users and server/function writes where appropriate.
- **Cloud Functions**: Enforce `context.auth` on callables (`nearbyPostboxes`, `startScoring`, future friends/leaderboard endpoints); reject unauthenticated callers and validate inputs.
- **Secrets**: No API keys or service account JSON paths in the repo; use env/config and secure storage for release builds.
- **Rate limiting / abuse**: Consider rate limits on callables and abuse detection for claims (e.g. same device, location spoofing).
- **PII**: Limit PII in claims and leaderboard display (e.g. display names only); comply with privacy policy and data deletion requests.

### Added features to encourage engagement

- Streaks for daily claims; achievements/badges.
- “Postbox of the day” or rare-find highlights; push reminders.
- Friend challenges; seasonal or regional leaderboards.
- Sharing a claim to social; Postman James unlockable lines or reactions.
- Light narrative or collectible angle tied to monarch eras.
