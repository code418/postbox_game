# H2 — Streak map

- **Status:** Proposed
- **Screen:** Profile screen (or a dedicated streak view)
- **Effort:** Small (given G2/H1 exist)
- **Privacy:** Compatible (user's own data) — requires backend change

## Overview

Show a polyline on a map connecting the postboxes claimed during the
user's current active streak, in chronological order. Celebrates the
daily habit with a visible trail of "today → yesterday → two days ago".
Breaks if the streak breaks.

## User flow

1. User opens **Profile** and sees their current streak badge (already
   exposed via `StreakService`).
2. Tapping the badge opens a **Streak map** view.
3. A map shows the claimed postboxes contributing to the streak —
   numbered 1, 2, 3... in the order claimed.
4. Connected by a gold polyline (matching the "streak" aesthetic with
   `postalGold`).
5. Summary: "7 days · 9 claims · 4 distinct ciphers".
6. Empty state if streak is 0: "Start your streak by claiming today."

## Technical approach

- Extend the `getUserClaimHistory` function (from G2) to accept a
  `sinceDate` parameter.
- Client computes the streak start from `StreakService` and passes it.
- Render as in G2 but with gold polyline and numbered markers (`Marker`
  child = a numbered badge).

## Files affected

- `functions/src/index.ts` — extend `getUserClaimHistory` with
  `sinceDate`.
- `lib/streak_map_screen.dart` — new screen.
- `lib/home.dart` — wire up streak badge tap.

## Backend changes

Shared with G2. Parameter addition only.

## Privacy considerations

- User's own data only.

## Open questions

- If the streak is one day long (one claim), what does the "map" look
  like? Consider showing a single pin with a motivational message.
- Should long streaks (>90 days) use clustering?
- Should broken streaks persist as a "best streak" view?
