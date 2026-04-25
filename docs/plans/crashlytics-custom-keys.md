# Plan — Crashlytics custom keys and non-fatal logging

- **Status:** Proposed
- **Effort:** Small
- **Firebase services:** Crashlytics

## Overview

Crashlytics is already configured. Add structured context so crashes are diagnosable without a repro, and promote handled exceptions in key flows to non-fatals so they're visible in the dashboard.

## Custom keys to set on the current session

- `auth_state` — `anon | email | google`.
- `active_tab` — `nearby | claim | leaderboard | friends`.
- `last_claim_id`.
- `last_monarch`.
- `remote_config_fetch_ts`.
- `has_location_permission` — bool.

## Non-fatals to record

- Catch blocks in `UserRepository.signIn*` → `recordError` with `fatal: false`.
- Callable failures in `nearbyPostboxes` and `startScoring`.
- `FlutterCompass` unexpected stream errors.
- Firestore snapshot errors on leaderboard.
- App Check token fetch failures.

## Implementation

- `lib/services/crashlytics_helper.dart` with:
  - `setContext({ key, value })` — typed wrapper with length guards.
  - `recordHandled(error, stack, { reason })` — always `fatal: false`.
- Centralise tab changes in `home.dart` to set `active_tab` once.
- Route all callable wrappers through a helper that logs to Crashlytics on failure and rethrows.

## Privacy

- Never log user email, display name, or exact coordinates as custom keys.
- Crashlytics opt-out is already honoured by Firebase; keep current user-consent path.

## Rollout

- No flag needed — purely additive.
- Ship; watch dashboard for new non-fatals; tune which ones matter.

## Risks

- Noisy non-fatals from expected network flakes — rate-limit or drop after first per session.

## Testing

- Unit test the helper's length-guard truncation.
- Force a non-fatal in debug builds to verify ingestion.
