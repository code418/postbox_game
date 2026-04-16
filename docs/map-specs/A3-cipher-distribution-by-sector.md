# A3 — Cipher distribution by sector

- **Status:** Proposed
- **Screen:** Nearby (`lib/nearby.dart`)
- **Effort:** Medium
- **Privacy:** Requires backend change

## Overview

Like A1 but colour-codes each of the 8 sectors by the dominant cipher type
present there. For example, if the NE sector has 2 EIIR and 1 VR postboxes,
the wedge is split into thirds showing the cipher colours from
`MonarchInfo.colors`. Gives a sense of "which direction has the rare
postboxes" without revealing exact positions.

## User flow

1. User runs a nearby scan.
2. New expandable card below the monarch breakdown: **"What's where?"**.
3. Expanded: a map with 8 wedges, each split proportionally into cipher
   colour bands.
4. A legend below shows cipher labels with their colours.
5. Tapping a wedge shows a small popup: "NE: 2 Elizabeth II, 1 Victoria".

## Technical approach

- Server needs to return per-sector cipher counts, e.g.
  `compass.NE.EIIR = 2, compass.NE.VR = 1`.
- Client builds 8 outer wedges, then sub-divides each radially by cipher
  proportion.
- Use `Polygon` with per-slice colours from `MonarchInfo.colors`.

## Files affected

- `functions/src/_lookupPostboxes.ts` — extend compass output to include
  per-cipher breakdown per direction.
- `functions/src/index.ts` — `nearbyPostboxes` response type.
- `lib/nearby.dart` — add new section.
- `lib/widgets/sector_heatmap.dart` — extend to support per-cipher slicing.
- `functions/src/test/` — update tests.

## Backend changes

`nearbyPostboxes` returns a nested structure:

```json
{
  "compass": {
    "N":  { "EIIR": 3, "VR": 0, "GVR": 1, ... },
    "NE": { "EIIR": 2, "VR": 1, ... },
    ...
  }
}
```

## Privacy considerations

- Still only sector-level aggregation (same 45° buckets).
- Cipher breakdown per sector could narrow down searches ("rare cipher is
  NE"), but does not give an exact position within a 540 m × 45° wedge.
- **Does NOT reveal specific postbox locations**, but gives slightly more
  information than A1. Product should decide whether this still sits within
  the "fuzzy compass" spirit.

## Open questions

- Is per-sector cipher breakdown too much information for the
  "encourage exploration" design intent?
- Consider limiting to a single "dominant cipher" per sector instead of a
  full breakdown.
