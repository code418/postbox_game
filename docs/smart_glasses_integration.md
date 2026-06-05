# Smart-glasses (Android XR) integration — feasibility & design

> **Status: exploration.** Nothing in this document ships behaviour. The
> companion changes in this PR (the `xr` product flavour and an empty
> `android/app/src/xr/AndroidManifest.xml`) reserve the build scaffolding
> so a follow-up PR can drop in the first real activity without reshaping
> Gradle first.

## Goal

Postbox Game is a "look around the real world, spot postboxes, claim
them" game. Smart glasses are a near-perfect form factor for the loop:
the player is already walking, already looking, and the **fuzzy
compass** (the deliberately-imprecise direction hint described in
`CLAUDE.md`) maps naturally onto a translucent HUD ring.

The smart-glasses experience we want to explore:

- Walk down a street wearing the glasses.
- A faint compass ring overlay shows red sectors where unclaimed
  postboxes lie and grey sectors for already-claimed ones — **no pins,
  no distances**, same fuzziness guarantee as the phone app.
- Postman James whispers a non-sequitur in the player's ear when the
  player glances toward a sector: "Something Victorian-ish over that
  way, I reckon."
- Saying "claim" while standing near a postbox runs the same
  `startScoring` flow as the phone — quiz prompt is read aloud,
  response captured by ASR.
- Standard stats ("what's my streak?", "who's leading today?") are
  voice-answered against the same Firestore collections the phone and
  Wear OS clients read.

## SDK summary

Reference: <https://developer.android.com/develop/xr/jetpack-xr-sdk/ai-glasses/build>

The Jetpack XR AI-glasses SDK is **Kotlin + Jetpack Compose Glimmer
only**. There is no Flutter engine on the glasses surface, so this
cannot be a Dart entrypoint like `lib/main_wear.dart`.

Relevant artefact families (exact coordinates not yet pinned by Google
— deps are commented out in `android/app/build.gradle` until the SDK
leaves alpha):

| Family | Purpose |
| --- | --- |
| `androidx.xr.compose` | Spatial UI with Compose Glimmer (HUD cards, chips, lists) |
| `androidx.xr.scenecore` | 3D entities, spatial audio cues |
| `androidx.xr.arcore` | Device pose (where the user is looking), depth, hand tracking |

What the XR SDK does **not** provide and we still need from stock
Android:

- `android.location.LocationManager` / `FusedLocationProviderClient` for
  the user's GPS fix.
- `android.hardware.SensorManager` (magnetometer + accelerometer) for
  the compass heading that drives the fuzzy-compass sectors. ARCore
  device pose gives head orientation in the world frame, but we still
  need true north.
- System TTS (`android.speech.tts.TextToSpeech`) for Postman James
  lines.
- On-device ASR (`android.speech.SpeechRecognizer`) for "claim", "what's
  nearby", "who's leading".

## Architecture

Mirror the existing **Android Auto** integration, which is the closest
pattern in this repo: a separate native-Kotlin surface that talks to
Firebase directly without ever loading the Flutter engine.

Reference files (do not modify these in this PR; they are the proven
template the XR surface will copy):

- `android/app/src/phone/kotlin/com/code418/postbox_game/car/PostboxCarAppService.kt`
- `android/app/src/phone/kotlin/com/code418/postbox_game/car/HomeCarScreen.kt`
- `android/app/src/phone/kotlin/com/code418/postbox_game/car/LeaderboardCarScreen.kt`
- `android/app/src/phone/kotlin/com/code418/postbox_game/car/StatsRepository.kt`
- `android/app/src/phone/kotlin/com/code418/postbox_game/car/ClaimAction.kt`

Proposed `android/app/src/xr/kotlin/com/code418/postbox_game/xr/`
layout (no files yet — follow-up PR):

| File | Responsibility | Lifted from |
| --- | --- | --- |
| `PostboxXrActivity.kt` | Compose Glimmer entry. Hosts the HUD scaffold and routes voice intents. | New |
| `FuzzyCompassHud.kt` | Compose Glimmer port of `lib/fuzzy_compass.dart` (`to8Sectors`, `vagueLabel`, sector painter). Draws claimed sectors grey and unclaimed sectors red around a North marker. | `lib/fuzzy_compass.dart` |
| `StatsRepository.kt` | One-shot reads of `users/{uid}` and `leaderboards/daily`. Mirrors the staleness check (discard if `periodKey` ≠ London-today). | `.../car/StatsRepository.kt` |
| `XrClaimAction.kt` | Auth check → fresh GPS fix → call `startScoring` callable → map result to `Claimed` / `Empty` / `AlreadyClaimedToday` / `TooFast` / `NotSignedIn` / `Error`. | `.../car/ClaimAction.kt` (almost verbatim) |
| `NearbyController.kt` | Calls the `nearbyPostboxes` callable, feeds `claimedCompassCounts` / `unclaimedCompassCounts` into the HUD. | New, but the callable contract is documented in `functions/src/index.ts` |
| `VoiceController.kt` | TTS + ASR wrapper. Maps "claim" / "what's nearby" / "who's leading" / "my streak" to actions. Reads Postman James lines from a Kotlin port of `lib/james_messages.dart`. | New |

## Server-side reuse

**No backend changes.** Every server-side need is already satisfied by
the existing callables documented in `CLAUDE.md` and exported from
`functions/src/index.ts`:

- `nearbyPostboxes` — returns `claimedCompassCounts` and
  `unclaimedCompassCounts` (the exact shape the fuzzy compass HUD
  needs).
- `startScoring` — handles the claim, quiz, streak update and
  leaderboard write.
- `userClaimHistory` — stats for the voice-answered "how am I doing?"
  query.

This means:

- No new Cloud Functions.
- No Firestore schema changes.
- No `firestore.rules` / `storage.rules` changes.
- No `pubspec.yaml` changes (Flutter side is untouched).

The fuzzy-compass contract from `CLAUDE.md` ("Avoid showing exact
bearings or distances that would allow pinpointing") still holds on
glasses — the HUD must only ever show 8-wind sectors, never a heading
needle pointing at a specific box.

## UX constraints

The glasses form factor reshapes UX in ways worth recording up front:

- **Voice-first.** Tap and pinch gestures exist but assume the player
  is mid-walk with hands occupied (umbrella, dog lead, phone-camera
  for photo evidence). Default every action to voice.
- **No full-screen UIs.** Compose Glimmer HUD chips and cards only.
  Anything that occludes the player's view of an oncoming bus is a
  bug.
- **Battery-conscious.** Don't poll ARCore device pose continuously —
  only during an explicit "look around" gesture or voice command.
- **Privacy.** The glasses camera is **not** used for postbox claim
  evidence in this design (UK street photography legality + bystander
  privacy). The phone app remains authoritative for the
  problem-reporting photo flow described in `CLAUDE.md`.
- **Auth.** Most AI-glasses pair with a phone and inherit its Google
  session — we expect the existing Firebase Auth flow to "just work",
  but it's an open question (see below).

## Risks and open questions

- **SDK maturity.** Jetpack XR is alpha at time of writing. Artefact
  coordinates and minSdk are not pinned in the public docs; the
  `xrImplementation` block in `android/app/build.gradle` is commented
  out until that settles.
- **GPS accuracy on glasses.** The phone uses a 30 m claim radius. If
  the glasses fix is noisier (no GNSS antenna, paired-phone tether),
  we may need to relax `metresBounds` for XR-originated calls — but
  doing so would weaken the travel-speed anti-spoof check in
  `startScoring`. Worth measuring before we decide.
- **Shared-headset accounts.** Unclear whether a single pair of
  glasses can switch between Google accounts mid-walk. If not, family
  / shared-device use cases get awkward.
- **OSM data freshness on glasses.** The fuzzy-compass HUD relies on
  Firestore data ingested from OpenStreetMap. No change to that
  pipeline — but if a player is in an area with sparse OSM coverage,
  the HUD will look empty in a way that is harder to explain than on
  the phone (no list view to fall back to).
- **Postman James voice.** Lines in `lib/james_messages.dart` were
  written for the screen, not the ear. Some will need rewording for
  TTS pacing.

## Phased rollout

| Phase | Scope | Branch shape |
| --- | --- | --- |
| 1 (this PR) | `xr` product flavour, empty `src/xr/` manifest, this doc. | `claude/smart-glasses-integration-jf0kW` |
| 2 | Read-only HUD prototype: `PostboxXrActivity` + `StatsRepository` showing today's points / streak / rank. Mirrors the Android Auto stat panel. | follow-up |
| 3 | Voice-driven claim. `XrClaimAction` + `VoiceController` wired to `startScoring`. | follow-up |
| 4 | Live fuzzy-compass overlay. `NearbyController` + `FuzzyCompassHud`, sensor-fusion heading. | follow-up |
| 5 | Public alpha behind a Firebase Remote Config flag, opt-in via the existing settings screen. | follow-up |

Each phase is small enough to ship behind feature-flag and back out if
the SDK shifts under us.

## What this PR actually changes

Just the build harness and this document. Specifically:

- `android/app/build.gradle` — add `xr` product flavour and a
  commented `xrImplementation` dependency block.
- `android/app/src/xr/AndroidManifest.xml` — new, manifest-only
  source set declaring `android.software.xr.immersive`. No activities,
  no services.
- `docs/smart_glasses_integration.md` — this file.

Nothing under `lib/`, `functions/`, `firestore.rules`,
`storage.rules`, `pubspec.yaml`, `firebase.json`, the `wear` source
set, or the `phone` source set is touched.
