# C2 — Regional leaderboards with map selector

- **Status:** Proposed
- **Screen:** Leaderboard (`lib/leaderboard_screen.dart`) — new "Regional" tab
- **Effort:** Large
- **Privacy:** Compatible (coarse aggregation) — requires backend change

## Overview

Add a map-based filter to the leaderboard so players can see "who's on top
in my city/county". Tapping a region on a UK outline map filters the
leaderboard to scores earned from claims within that region.

## User flow

1. User opens a new **Regional** tab on the leaderboard.
2. A UK map renders with county outlines.
3. User taps a county (e.g. Greater London). The county highlights and the
   leaderboard below shows scores from claims within it.
4. Tabs for Daily / Weekly / Monthly / Lifetime work as before but filtered
   by region.
5. Empty counties show "No claims yet in this region".

## Technical approach

- Server partitions leaderboard data by region:
  `leaderboards/{period}/regions/{region}/entries/{uid}`.
- On each claim, the `startScoring` Cloud Function looks up which region
  the postbox sits in (a property on the `postbox` document or a
  server-side geo lookup) and increments the matching regional leaderboard.
- Import counties from an open dataset (ONS / OS Open Data) as GeoJSON,
  simplified to <500 KB.
- Render county polygons via `PolygonLayer`; use `GestureDetector` in a
  custom `MarkerLayer` for hit-testing, or tap-on-polygon detection.

## Files affected

- `functions/src/_getPoints.ts` — look up region from postbox.
- `functions/src/startScoring.ts` — write to regional leaderboards.
- `functions/import_postboxes.js` — add region field on import.
- `assets/uk_counties.geojson` — simplified GeoJSON.
- `lib/leaderboard_screen.dart` — new Regional tab with map selector.
- `pubspec.yaml` — add GeoJSON parsing package if needed.

## Backend changes

- Region field on every `postbox` document.
- New regional leaderboard subcollections.
- Region lookup utility (point-in-polygon check or simpler precomputed
  mapping).

## Privacy considerations

- Region-level aggregation is coarse enough to not reveal postbox or user
  positions.
- Leaderboard already shows display names only.

## Open questions

- What level of region? Counties (~100 regions), local authorities (~400),
  parliamentary constituencies (~650)?
- Should Scotland, Wales, Northern Ireland each have their own sub-region
  structure?
- How to handle users who straddle regions (e.g. commute between London
  and Surrey)?
