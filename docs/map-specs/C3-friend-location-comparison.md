# C3 — Friend location comparison map

- **Status:** Proposed
- **Screen:** Leaderboard — Friends tab (`lib/leaderboard_screen.dart`)
- **Effort:** Medium
- **Privacy:** Opt-in — requires backend change

## Overview

On the Friends leaderboard tab, display a UK map with a coloured dot per
friend showing their primary activity area (city-level precision). Gives a
friendly "look where Sarah's playing" feel without exposing exact
positions.

## User flow

1. User opens the Friends leaderboard tab.
2. Above the list, a UK map shows dots — one per friend who has opted in.
3. Each dot is placed at the centroid of that friend's most active
   geohash 3 cell (~150 km² — city-level).
4. Dot size reflects claim count; colour is fixed per friend avatar tone.
5. Tapping a dot shows their display name and rank.
6. The current user's dot is highlighted with a red ring.

## Technical approach

- Reuse the geohash coverage from spec C1.
- For each friend, the dot is placed at the centroid of their most
  claimed geohash 3 cell.
- Requires friend opt-in to share coverage data.
- Settings toggle: "Share my coverage with friends".

## Files affected

- `lib/settings_screen.dart` — new "Share coverage" toggle.
- `functions/src/index.ts` — extend friend data endpoint to include
  optional coverage summary.
- `firestore.rules` — allow friends to read coverage if shared.
- `lib/leaderboard_screen.dart` — new map at the top of Friends tab.

## Backend changes

- Per-user `shareCoverage` boolean flag.
- Friend-readable endpoint returning coverage summary if opted in.

## Privacy considerations

- City-level precision (~150 km²) avoids pinpointing anyone's home.
- Strict opt-in: off by default.
- Only shared with accepted friends (not public).
- Users can revoke at any time; friends see a grey "?" dot if not shared.

## Open questions

- Is "most active geohash 3 cell" the right signal, or recent activity?
- Should the centroid be jittered to avoid consistent pinpointing?
- Handle users who travel frequently — multiple dots or just the peak?
