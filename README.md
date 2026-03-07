# The Postbox Game

**Find postboxes. Claim them. Score mega points.**

A location-based game that turns real-world UK postboxes into collectible targets. Discover postboxes near you, visit them in person to claim them, and climb the leaderboard. Different postbox eras (e.g. EIIR, GR, VR) award different point values, so hunting for rarer boxes pays off.

---

## Overview

The Postbox Game is a Flutter mobile app backed by Firebase. Players sign in, use **Nearby Postboxes** to see how many postboxes are in range and in which direction (compass-style), then use **Claim Postbox** when they’re at a postbox to claim it and earn points. Progress is stored in Firestore; friends and **Leaderboard** screens let you compare scores. A first-run intro introduces Postman James and the rules; settings cover sign out, distance units, and replaying the intro.

---

## How it works

1. **Find** — Open *Nearby Postboxes*, allow location, and see counts and a fuzzy compass for postboxes around you (no turn-by-turn navigation; exploration is part of the game).
2. **Claim** — When you’re at a postbox, open *Claim Postbox*, refresh location, then tap *Claim postboxes here*. The backend records your claim and awards points based on the postbox type. Daily streaks are tracked for extra motivation.
3. **Compete** — Add friends and check the leaderboard to see who’s ahead.

---

## Features

- **Auth** — Sign in with Google or email; route guards keep protected screens (Nearby, Claim) for signed-in users only.
- **Nearby** — Cloud Function returns postbox counts and compass buckets for a given location and radius.
- **Claim** — Cloud Function `startScoring` records claims for the authenticated user and updates points; optional daily streak.
- **Friends & leaderboard** — Firestore-backed social and rankings.
- **Intro** — First-run cinematic with Postman James; replayable from Settings.
- **Settings** — Sign out, replay intro, distance units (meters/miles), and About.

---

## Tech stack

- **App:** Flutter (Dart 3), BLoC for auth state, Firebase Auth, Firestore, Cloud Functions (callables).
- **Backend:** Firebase (Auth, Firestore, Cloud Functions in TypeScript). Postbox data sourced from OpenStreetMap-style geometry (UK).
- **Local:** `shared_preferences` for first-run intro and app preferences (e.g. distance units).

---

## Platforms

The app supports **mobile** (Android, iOS), **web**, and **desktop** (Windows, Linux, macOS).

- **Android / iOS** — Full support; Firebase options are configured for Android; run `dart run flutterfire configure` to add iOS.
- **Web** — Firebase is configured for web. Build with `flutter build web`; deploy to Firebase Hosting from `build/web` (see `firebase.json`). If the web build fails with `PromiseJsImpl` errors (Dart 3 / web interop), consider upgrading Firebase packages when compatible (e.g. `firebase_core`, `firebase_auth`) or run on Chrome with `flutter run -d chrome` to test.
- **Desktop** — Windows, Linux, and macOS use the same Firebase config as web so the app runs without extra setup. Location and compass features depend on device support (e.g. browser/OS permissions on web, system location on desktop). Linux and Windows builds have been verified; run `flutter build linux` or `flutter build windows` on the respective host.

### Run the app

```bash
flutter pub get
flutter run
```

To run on a specific platform:

```bash
flutter run -d chrome          # Web
flutter run -d windows         # Windows desktop
flutter run -d linux           # Linux desktop
flutter run -d macos           # macOS desktop
```

### Firebase

- Ensure **Firebase** is initialized (e.g. `DefaultFirebaseOptions` from `firebase_options.dart`).
- Deploy **Cloud Functions** from the `functions/` directory (e.g. `nearbyPostboxes`, `startScoring`).
- Deploy **Firestore rules** from `firestore.rules` if present.

### First run

On first launch, the app shows the Postman James intro, then the login/register screen. After that, opening the app goes straight to home or login depending on auth state.

---

## Project structure (high level)

- `lib/` — Flutter app (screens, BLoC, intro, settings, preferences).
- `functions/` — Firebase Cloud Functions (TypeScript) for nearby postboxes and claiming.
- `firestore.rules` — Firestore security rules (when used).
- `assets/` — Images and assets (e.g. compass, james).

For detailed navigation and feature branches, see the codebase and any internal planning docs (e.g. `plan/CLAUDE.md` if present).
