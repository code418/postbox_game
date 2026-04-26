# Plan — Remote Config for game balance and copy

- **Status:** Proposed
- **Effort:** Small (client) + tiny (backend)
- **Firebase services:** Remote Config, Remote Config server-side SDK (Node)

## Overview

Centralise tunable values so game balance, reminder copy, and James cadence can change without a client release. Both the Flutter client and Cloud Functions read Remote Config.

## Parameters (initial set)

| Key | Default | Notes |
|-----|---------|-------|
| `claim_radius_meters` | `30` | Used by `startScoring` geohash + distance check. |
| `points_by_monarch` | JSON `{EIIR:2,GR:4,...}` | Overrides hard-coded values in `_getPoints.ts`. |
| `james_idle_min_seconds` | `120` | Idle non-sequitur lower bound. |
| `james_idle_max_seconds` | `300` | Upper bound. |
| `daily_reminder_hour_local` | `18` | Push time. |
| `daily_reminder_copy` | James-voice string | Localisable per monarch era. |
| `nearby_radius_meters` | `540` | Compass / heatmap range. |
| `quiz_required_streak` | `7` | Quiz gates post-streak day. |

## Client

- Add `firebase_remote_config` to `pubspec.yaml`.
- `lib/services/remote_config_service.dart` — fetch-and-activate on app start (min interval 1 h in prod, 0 in debug), exposes typed getters.
- Replace magic numbers in `home.dart`, `claim.dart`, `james_strip.dart`, `fuzzy_compass.dart`.

## Backend

- Add `firebase-admin` Remote Config fetch in `_config.ts` with 5 min in-memory cache.
- `_getPoints.ts` reads `points_by_monarch` with fallback to current hard-coded table.
- `startScoring` uses `claim_radius_meters`.

## Rollout

- Phase 1: ship client reading only; values identical to current defaults.
- Phase 2: backend reading; verify via integration test with Remote Config emulator.
- Phase 3: tune via console, monitor Analytics for regressions.

## Risks

- Stale cache in the client masking a bad value — force a refetch hook at login.
- Cost drift if `points_by_monarch` is set incorrectly; add a sanity-check Cloud Function that rejects values outside `[1, 50]`.

## Testing

- Unit-test `RemoteConfigService` typed getters.
- Add emulator-backed test in `functions/src/test` that asserts `_getPoints` honours override.
