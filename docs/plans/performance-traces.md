# Plan — Performance Monitoring custom traces

- **Status:** Proposed
- **Effort:** Small
- **Firebase services:** Performance Monitoring

## Overview

Performance SDK is already pulled in. Add custom traces around the parts of the app that most affect user experience: callable round-trips, map tile loads, and the claim flow.

## Traces (initial)

| Trace name | Attributes | Scope |
|------------|------------|-------|
| `callable.nearbyPostboxes` | `resultsCount`, `radius` | `lib/nearby.dart` |
| `callable.startScoring` | `monarch`, `outcome` | `lib/claim.dart` |
| `map.tileLoad` | `zoom` | `lib/widgets/postbox_map.dart` |
| `friends.load` | `count` | `lib/friends_screen.dart` |
| `leaderboard.render` | `period`, `rowCount` | `lib/leaderboard_screen.dart` |
| `intro.onboarding` | `variant` | `lib/intro.dart` |

## HTTP traces

- Enable automatic HTTP request traces for external calls (e.g. OSM Nominatim if ever used).

## Implementation

- `lib/services/perf_service.dart` — helper `traceAsync<T>(name, attrs, fn)`.
- Keep trace count below 100 to stay in free tier.
- Name constants in a single file to prevent typo-driven trace fragmentation.

## Dashboards

- Configure in the Firebase console; no repo artefact needed.
- Add alerts on p95 latency regression > 50 % for `callable.startScoring`.

## Risks

- Over-instrumentation slows debug builds. Gate verbose traces behind `kDebugMode` negation where appropriate.

## Testing

- Smoke test on a physical device in release mode; verify traces appear in console within 24 h.
