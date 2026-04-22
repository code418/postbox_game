# A1 — Sector heatmap overlay

- **Status:** Proposed
- **Screen:** Nearby (`lib/nearby.dart`)
- **Effort:** Medium
- **Privacy:** Compatible

## Overview

Supplement the `FuzzyCompass` custom-paint widget with a real map view that
overlays the same 8-sector data onto local streets and landmarks. The map
shows only aggregated sector counts that the server already returns; no
individual postbox positions are revealed.

## User flow

1. User taps **Find nearby postboxes**.
2. Results screen shows the existing monarch-type cards and the fuzzy
   compass, then a new card labelled **"Heatmap"**.
3. The card contains a 200 px-tall map centred on the user with a 540 m
   radius circle and 8 translucent pie wedges (N, NE, E, SE, S, SW, W, NW).
4. Each wedge's opacity / fill saturation scales with the sector's count
   (0 → transparent, max → postal red at 0.5 alpha).
5. User can compare the compass view and the map view side-by-side.

## Technical approach

- Use `PostboxMap` from `lib/widgets/postbox_map.dart`.
- Build 8 `Polygon`s, one per sector. Each polygon is a pie wedge from the
  user's centre to a 540 m radius, spanning 45°, approximated by ~8 vertices
  along the arc.
- Merge the server's 16-wind `compassCounts` into 8 sectors using the same
  logic as `FuzzyCompass` (see `lib/fuzzy_compass.dart`).
- `PostboxMap(interactionOptions: InteractionOptions(flags: InteractiveFlag.none))`
  to keep the preview non-interactive; add a full-screen expand button.
- Use `Distance().offset(center, meters, bearing)` from `latlong2` to build
  wedge vertices.

## Files affected

- `lib/nearby.dart` — add new card in `_buildResults()`.
- `lib/widgets/sector_heatmap.dart` — new helper for building polygons.

## Backend changes

None. Uses the existing `nearbyPostboxes` Cloud Function response.

## Privacy considerations

- Only aggregated counts are visualised — same data the fuzzy compass
  already exposes.
- The 540 m radius circle is large enough that showing it does not pinpoint
  any postbox.
- Heatmap wedges deliberately span 45° (same granularity as the compass).

## Open questions

- Should the heatmap replace the fuzzy compass, or sit alongside it?
- Maximum opacity scaling: linear, logarithmic, or bucketed?
- Does showing the street grid tempt players to deduce postbox positions
  despite the sector-level granularity? Consider using a low-detail tile
  style (e.g. only major roads and parks).
