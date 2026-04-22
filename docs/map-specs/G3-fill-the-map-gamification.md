# G3 — "Fill the map" gamification

- **Status:** Proposed
- **Screen:** New full-screen map (reachable from Profile)
- **Effort:** Large
- **Privacy:** Compatible (user's own progress only) — requires backend change

## Overview

Divide the UK into a grid of cells (geohash or OS grid squares). Cells
turn from grey to colour as the user claims at least one postbox within
them. Creates a "fill the map" collection mechanic that incentivises
travel, new neighbourhoods, and diversity of hunting spots.

## User flow

1. User opens **Profile → Fill the map**.
2. A full-screen UK map shows a grid overlay (e.g. 10 km × 10 km cells).
3. Cells the user has at least one claim in are filled with postal red.
4. A progress bar at the top shows "Filled: 34 / 2,400 cells (1.4 %)".
5. Filters: filled / unfilled / all.
6. Tapping a filled cell shows stats: number of claims, rarest cipher,
   first claim date.

## Technical approach

- Use a fixed grid: geohash precision 5 (~5 km cells) for fine
  granularity, or precision 4 (~20 km) for a more achievable "fill".
- Reuse the coverage subcollection proposed in C1 for the source of
  truth.
- Client precomputes total cell count by intersecting the grid with a
  UK outline GeoJSON.
- Render each cell as a `Polygon` via `PolygonLayer`.

## Files affected

- `assets/uk_outline.geojson` — simplified UK border.
- `lib/fill_the_map_screen.dart` — new screen.
- Reuses the coverage pipeline from C1.

## Backend changes

- Shared with C1.

## Privacy considerations

- Data is the user's own; same as G2.
- No sharing by default.
- Public leaderboards could show "most cells filled" without revealing
  which cells.

## Open questions

- Grid type: geohash (simple, well-supported) vs. OS National Grid
  squares (UK-standard, more evocative). Recommend geohash for
  simplicity.
- Cell size: 5 km gives 2,400 cells in the UK — a multi-year goal.
  20 km gives ~200 cells — achievable in a year. Consider both and
  switch at a toggle.
- Coastal cells: what fraction of a cell must be land before it counts?
  Inclusive default (any land) vs. strict (majority land).
- Should uncoverable cells (offshore, military) be visually hidden?
