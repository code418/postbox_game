# Plan — Custom Analytics events and BigQuery export

- **Status:** Proposed
- **Effort:** Small
- **Firebase services:** Analytics, BigQuery export

## Overview

Instrument key user actions and enable the Firebase Analytics → BigQuery daily export, so cohort, funnel, and retention analysis can be run in SQL.

## Custom events (initial)

| Event | Params | Where |
|-------|--------|-------|
| `claim_success` | `monarch`, `region`, `points`, `isFirstOfDay` | `claim.dart` |
| `claim_failed_quiz` | `monarch` | `claim.dart` |
| `nearby_viewed` | `resultsCount` | `nearby.dart` |
| `compass_viewed` | `sectorsShown` | `fuzzy_compass.dart` |
| `friend_added` | `method: "uid"` | `friends_screen.dart` |
| `leaderboard_viewed` | `period`, `friendsOnly` | `leaderboard_screen.dart` |
| `james_line_shown` | `category` | `james_strip.dart` |
| `streak_broken` | `previousStreak` | backend mirror |
| `signup_complete` | `provider` | `register/` |

## Implementation

- `lib/services/analytics_service.dart` — typed wrapper over `firebase_analytics`.
- Replace any direct `FirebaseAnalytics.instance.logEvent` calls with the wrapper.
- Strictly validate param types and max-length per Google's limits.

## BigQuery

- Enable the linked BigQuery dataset in the Firebase console (1 ds per project, daily export).
- Create a `views/` directory in the repo with SQL for common slices (DAU, funnel, claim density by region).
- Document each view in `docs/analytics/`.

## Privacy

- Do not log PII in event params (no emails, no display names, no exact coordinates — use `region` outcode).
- Add an opt-out toggle in settings; when off, call `setAnalyticsCollectionEnabled(false)`.

## Rollout

- Ship event wrapper first.
- Enable BigQuery export when there is at least one view ready to consume it.

## Risks

- Event count inflation costs BQ storage — trim noisy events (e.g. `james_line_shown`) if volume is excessive.
- Privacy review before adding new params containing user input.
