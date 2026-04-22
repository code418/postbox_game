# I2 — "Postbox of the day" map card

- **Status:** Proposed
- **Screen:** Home (new card) or push notification
- **Effort:** Medium
- **Privacy:** Requires careful design — potentially conflicts with rules

## Overview

A daily featured postbox — perhaps a rare cipher that's been unclaimed
for a while, or one with a historic photo — highlighted via an in-app
card or push notification. Shows an approximate location on a small map.

## Rule tension

Featuring a specific unclaimed postbox with any location information is
**effectively directing players to it**, which crosses into the
"looking up locations in advance" rule.

## Acceptable variants

### Variant A — Regional highlight, no position
"A rare Victorian postbox was claimed in Yorkshire today." No map, no
location. Safe. Celebrates rarity without directing.

### Variant B — Already-claimed featured box
Highlights a postbox claimed **yesterday** by someone else, with the
location shown (the spec author assumes revealing claimed-by-others
positions is acceptable since the box is already in the game's public
leaderboard flow). Needs product sign-off.

### Variant C — Seasonal or event-based
"The most-claimed postbox last month was in central Manchester."
Historical / aggregate; safer.

## User flow (Variant A — recommended)

1. In-app banner on Home tab: "Today's feature: a Victorian postbox was
   found in Yorkshire yesterday. Will one be found today?"
2. No map needed; text only.
3. Push notification version: same text.

## Technical approach

- Cloud Scheduler runs daily, picks a featured event from yesterday's
  claims.
- Store the feature in `daily_features/{date}` with `{ cipher, region }`.
- Client fetches the current day's feature on app open and renders a
  banner.
- Push notification via FCM.

## Files affected

- `functions/src/dailyFeature.ts` — new scheduled function.
- `lib/home.dart` — new banner widget.
- `lib/daily_feature_service.dart` — new service.

## Backend changes

- New scheduled Cloud Function and Firestore collection.
- FCM push notification setup (not yet in the app — see "Push
  notifications" from the roadmap in `CLAUDE.md`).

## Privacy considerations

- Variant A exposes no personal data.
- Variant B requires careful sign-off — showing a specific claimed-box
  location publicly.
- Variant C is aggregated.

## Open questions

- Does a text-only Variant A warrant a map spec at all? Possibly
  downgrade to a non-map feature.
- Should the daily feature rotate: stats on Monday, rare cipher
  celebration on Tuesday, etc.?
