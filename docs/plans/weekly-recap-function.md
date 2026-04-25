# Plan — Weekly and monthly recap

- **Status:** Proposed
- **Effort:** Medium
- **Firebase services:** Cloud Functions (scheduled), Firestore, FCM

## Overview

Every Sunday evening, generate a per-user recap of the week's activity. Show as an in-app James monologue with shareable stats. Mirror monthly on the 1st.

## Data model

- `recaps/{uid}/periods/{YYYY-WW}` (ISO week) and `recaps/{uid}/periods/{YYYY-MM}`:
  - `{ claims, uniquePostboxes, rarestMonarch, topFriend, rankDelta, generatedAt }`.

## Generation

- Scheduled function `generateWeeklyRecaps` Sunday 18:00 London.
- For each user with ≥1 claim that week: aggregate claims, compute rank delta vs. previous week, pick a James line from `james_messages` keyed by the most interesting stat ("A record week, squire!").
- Idempotent: skip if recap doc already exists for the period.
- Batched in chunks of 500 writes; yields between chunks to stay within function timeout.

## FCM

- Send one push per recap: "This week in postboxes..." with deep link to the recap screen.
- Respect `notificationPrefs.weeklyRecapEnabled`.

## Client

- New `lib/recap_screen.dart`: full-bleed scroll of stats with James narrating. Share button uses `share_plus` to produce a PNG card (render widget to image).
- Badge dot on home tab when an unread recap exists.

## Rollout

- Backfill-safe: on first run, only generate the current week forward.
- Flag `feature_recaps_enabled`.

## Risks

- Large batch job during peak hours — run at 18:00 when user activity is moderate; use firestore `commit` chunks of 400.
- Timezones — use London week boundaries; document behaviour for overseas users.

## Testing

- Unit test the aggregator with a fixture set of claims.
- Integration test with fake Firestore that validates idempotency on re-run.
