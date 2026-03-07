# Postbox Game – project context (CLAUDE.md)

## Project summary

Cross-platform (Flutter) mobile app + Firebase (Auth, Firestore, Cloud Functions, Crashlytics, Performance, Analytics, Storage). Core loop: find nearby postboxes (UK, monarch-era rarity), claim once per day for points; rarer = more points. Postbox data is sourced from **OpenStreetMap** (e.g. Overpass API); **test.json** is a sample of that data; the data is ingested and stored in the **cloud database** (Firestore) for the app to use. A **fuzzy compass** hints at where claimed vs unclaimed postboxes are (e.g. by rough direction), without precise locations, to encourage exploration. **Login is required before play**—users must sign in (e.g. Google / email) before accessing the main game. **Friends and leaderboards**: users can add friends and compete on **daily**, **weekly**, and **monthly** leaderboards. The in-app character **Postman James** introduces the game on first launch and acts as a persistent advisor (Theme Park–style) at the bottom of the screen, commenting on the user's actions with light British humour.

## Postman James (character)

- **Role**: Onboarding (first launch) and in-app advisor throughout the app.
- **Placement**: Introduces the concept on first launch; appears in a strip/panel at the **bottom of the screen** on other screens, commenting on what the user is doing.
- **Tone**: Light, British humour (like the advisor in Theme Park).
- **Current state**: Intro uses `lib/intro.dart` with a **placeholder** for Postman James (Flare removed; `flare_flutter` is incompatible with Dart 3). Chat-style window remains. The persistent "James at bottom commenting on actions" is not yet on all screens—revival should add a James strip (e.g. Rive or image) and contextual copy on Nearby, Claim, etc.

## Login before play

Enforce a login step before any play. When unauthenticated, show login/register (e.g. `LoginScreen`); when authenticated, show main app (Intro then Nearby/Claim etc.). Restore the commented-out auth branching in `lib/main.dart` so `Unauthenticated` → login screen, `Authenticated` → home/Intro; ensure Nearby and Claim are only reachable when signed in.

## Friends and leaderboards

Add ability to **add friends** (mechanism TBD: email, username, invite code, or Firebase Auth UID lookup). Maintain **leaderboards** for **daily**, **weekly**, and **monthly** windows (e.g. Firestore collections or Cloud Functions aggregating points from `claims` by user and time window; client or scheduled function to compute rankings). UI: Friends list/screen and Leaderboard screen(s) with tabs or segments for daily/weekly/monthly.

## Fuzzy compass

The app shows a **fuzzy compass** that gives the user an **indication** of where **claimed** and **unclaimed** postboxes are nearby (e.g. rough direction or "something in that direction"), **without** giving precise directions or exact locations. Goal: encourage exploration rather than turn-by-turn navigation. Implementation: use existing compass/nearby data (`lib/nearby.dart`, `lib/claim.dart`, `lib/compass.dart`, backend compass/distance data) but present directions in a deliberately imprecise way (e.g. cardinal or 8-wind sectors, optional distance band like "near"/"medium"/"far", and separate indication for claimed vs unclaimed). Avoid showing exact bearings or distances that would allow pinpointing.

## Key paths

- **App entry**: `lib/main.dart` → **if unauthenticated** → `LoginScreen` (or register); **if authenticated** → home (e.g. Intro then routes to `/upload`, `/nearby`, `/Claim`, **friends**, **leaderboard**). Currently login flow is commented out and app goes straight to Intro—revival must restore login gate and add friends/leaderboard routes.
- **Backend**: `functions/index.js` exports `nearbyPostboxes` and `startScoring`; `_lookupPostboxes.js` uses geohash + Firestore; `_getPoints.js` maps monarch (EIIR, GR, GVR, GVIR, VR, EVIIR, EVIIIR) to points. **New**: friends list and leaderboard data (Firestore: e.g. `users/{uid}/friends`, `leaderboards/daily|weekly|monthly` or aggregated in Cloud Functions).
- **Postbox data source and storage**: Postbox data is **sourced from OpenStreetMap (OSM)**—e.g. Overpass API (`amenity=post_box`, UK area). **test.json** in the repo is a sample of the OSM/Overpass response: nodes with `type`, `id`, `lat`, `lon`, and `tags` (e.g. `amenity`, `ref`, `royal_cypher`, `post_box:type`, `collection_times`, `postal_code`). This data is **not** queried from OSM at app runtime; it is **ingested and stored in the cloud database** (Firestore). The app and existing Cloud Functions read from Firestore only.
- **OSM→Firestore import pipeline (to implement)**: (1) Run Overpass query for UK `amenity=post_box` (see test.json structure). (2) For each node: compute geohash (e.g. ngeohash.encode(lat, lon, 9)), build Firestore document `{ position: { geopoint: GeoPoint(lat, lon), geohash: string }, monarch: tags.royal_cypher || null, ref: tags.ref, ... }`. (3) Batch write to `postboxes` collection (document ID can be OSM node id or a stable hash). (4) Ensure composite index on `postboxes` for `position.geohash` (orderBy/range queries). Can be a one-off script or scheduled Cloud Function.
- **Auth**: `UserRepository` + `AuthenticationBloc`; Google Sign-In + Email/Password; `firebase_options.dart` has **Android and Web** only—**iOS throws**.

## Critical issues

- **Functions**: (Fixed) Geohash logic uses **ngeohash** (replacing geofirex). Firestore uses **`database.collection('postboxes')`** and **`database.collection('claims').add(data)`**. **index.js** initializes admin with `if (!admin.apps.length) admin.initializeApp();` before requiring other modules.
- **Flutter SDK**: `pubspec.yaml` has `sdk: ">=2.12.0 <3.0.0"` — locks to Dart 2. Current Flutter uses Dart 3. Bump to e.g. `>=3.0.0 <4.0.0` and fix any breaking changes.
- **Bloc**: All three blocs use deprecated `initialState` and `mapEventToState`. Bloc 8.x prefers the constructor-based API (`on<Event>`) — migrate or keep if still supported in current bloc.
- **Geolocator**: App uses `desiredAccuracy: LocationAccuracy.high` (geolocator ^10). In geolocator 13+ prefer `locationSettings: LocationSettings(accuracy: LocationAccuracy.high)`.
- **Flutter Compass**: Code uses `FlutterCompass.events?.listen(...)` and `mounted` check for null safety. Package is lightly maintained; alternative: `sensors_plus` (magnetometer) with custom heading calculation.
- **Android**: Root `android/build.gradle` uses **jcenter()** (deprecated/removed), **Fabric** — Firebase Crashlytics no longer uses Fabric; use only the Firebase Crashlytics Gradle plugin. **compileSdkVersion 33**, **targetSdkVersion 30** — Play Store may require higher target (e.g. 33+). Kotlin 1.6.10 and AGP 7.1.3 are old; consider upgrading.
- **iOS**: No `Podfile` in repo (Flutter may regenerate). **`firebase_options.dart` throws for iOS** — run FlutterFire CLI to add iOS (and optionally macOS) config if you want iOS release.
- **firebase_dynamic_links**: Removed (Firebase deprecated Dynamic Links Aug 2025; was unused in lib).
- **Intro / Postman James assets**: Uses **flare_flutter** and **assets/james.flr** for James. Flare became Rive; `.flr` is legacy. Check if `flare_flutter` still works on current Flutter or migrate to **rive**. Design goal: James should also appear at the bottom of main screens (Nearby, Claim, etc.) with contextual, light British-humour comments—implement or restore this advisor strip if missing.
- **Font**: `intro.dart` uses `fontFamily: "Agne"` but no custom font declared in `pubspec.yaml` — may fall back to default.

## Tests

- `test/widget_test.dart` pumps `PostboxGame()` which calls `Firebase.initializeApp()` — unit tests need Firebase mocked or test will fail.
- Functions test `test/index.js` expects `nearbyPostboxes(request, res)` but the function is **onCall**, i.e. `(data, context)`; test is wrong and references undefined `projectConfig`.

## Security / release

`firebase_options.dart` and test file reference project ID **the-postbox-game** and service account path; ensure no secrets in repo for store release. Use environment/config for CI and store builds.

---

## Post-build review (suggestions only)

The project builds successfully (`flutter build apk`). The following are **suggestions only** for follow-up work.

### Next steps (prioritised)

1. **Login gate**: Restore auth branching in `main.dart` so unauthenticated users see `LoginScreen` and authenticated users see Intro/Home; protect Nearby and Claim routes (see plan §1).
2. **Friends and leaderboards**: Implement add-friend flow (email/username/invite per product decision), Firestore schema for `users/{uid}/friends` and aggregated leaderboard data, Leaderboard screen with daily/weekly/monthly tabs, and backend aggregation (Cloud Functions or scheduled jobs).
3. **Fuzzy compass UI**: Implement rough-direction and claimed vs unclaimed indication using existing compass/nearby data; avoid exact bearings or distances (see plan §1).
4. **Postman James**: Restore an animated James (e.g. migrate to Rive or use a static image) and add the persistent advisor strip at the bottom of Nearby, Claim, and other main screens with contextual copy.
5. **OSM→Firestore pipeline**: Implement or run the import/sync (Overpass → map to `postboxes` schema → batch write); ensure indexes.
6. **Tests**: Add Firebase/Flutter mocks so widget tests don’t call real Firebase; fix or run functions tests with the emulator.
7. **iOS**: Run `dart run flutterfire configure` and add iOS to `firebase_options.dart` if targeting iOS.
8. **Android build note**: If the declarative Flutter Gradle plugin fails with "null cannot be cast to Map", the Flutter SDK’s `NativePluginLoaderReflectionBridge.kt` may need to look for `getDependenciesMetadata` (not `dependenciesMetadata`) when reflecting on the plugin loader script.

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
