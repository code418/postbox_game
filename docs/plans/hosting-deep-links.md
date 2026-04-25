# Plan — Firebase Hosting + App Links / Universal Links (Dynamic Links replacement)

- **Status:** Proposed
- **Effort:** Medium
- **Firebase services:** Firebase Hosting, (indirect) Android App Links, iOS Universal Links

## Overview

Dynamic Links is deprecated and already removed from the project. This plan adds a minimal Hosting site that serves deep-link landing pages and the required Android `assetlinks.json` / Apple `apple-app-site-association` (AASA) files so shared URLs open directly in the app when installed, and fall back to a web preview otherwise.

## Deep-link surfaces (initial)

- `/claim/{claimId}` — a specific claim share card ("I claimed a VR box in BS8!").
- `/u/{uid}` — public profile preview (display name + simple stats, with a "Play" CTA).
- `/challenge/{id}` — friend challenge invite landing page.

## Hosting setup

- New `hosting/` directory at repo root with:
  - `firebase.json` hosting section.
  - `public/index.html` simple landing.
  - `public/.well-known/assetlinks.json` (Android App Links verification).
  - `public/.well-known/apple-app-site-association` (served as `application/json`).
- Cloud Functions rewrites for the three routes → render a small server-side HTML with OG tags, then JS-attempt to open the app via intent URI.

## Android

- Add `android:autoVerify="true"` intent filter for the Hosting domain.
- `assetlinks.json` contains the app's signing cert SHA-256.

## iOS

- Add Associated Domains capability (`applinks:postbox.example`).
- AASA lists `claim`, `u`, `challenge` paths.

## Flutter

- Use `app_links` package (ongoing alternative to `uni_links`).
- Central deep-link router mapping `/claim/*` → `Nearby`, `/u/*` → `UserProfilePage`, `/challenge/*` → challenge accept screen.

## Rollout

- Ship Hosting first, verify `/.well-known/assetlinks.json` responds.
- Ship app with intent filters behind a feature flag (default on after verification).
- Provide a share button on claim success that emits the Hosting URL.

## Risks

- DNS + cert must be provisioned before release — add to the shipping checklist.
- App Links require exact cert SHA — debug and release builds have different certs; serve both.

## Testing

- Use `adb shell am start` with a Hosting URL to assert the app opens directly.
- Test AASA in Simulator with `xcrun simctl openurl`.
