# A2 — "You Are Here" context map

- **Status:** Proposed
- **Screen:** Nearby (`lib/nearby.dart`)
- **Effort:** Small
- **Privacy:** Compatible

## Overview

A small non-interactive map (~150 px tall) at the top of the Nearby results
screen showing the user's current position with the 540 m scan radius drawn
as a postal-red circle. No postbox pins — the map simply provides geographic
context so the user understands what area was scanned.

## User flow

1. User runs a nearby scan.
2. Above the summary card (`$_count postboxes nearby`), a small map appears
   showing the user at the centre with a translucent red disc for the scan
   radius.
3. Map is not pannable or zoomable — purely informational.
4. Tapping the map opens a larger version (optional, see K1 map/list toggle).

## Technical approach

- Use `PostboxMap` with `InteractionOptions(flags: InteractiveFlag.none)`.
- Pass the `position` returned by `getPosition()` in `_startSearch()`
  (already captured on `nearby.dart:89`).
- Add one `CircleMarker` via `scanRadiusCircle(center, radiusMeters:
  AppPreferences.nearbyRadiusMeters)`.
- Add one `userPositionMarker(center)`.
- Fixed zoom: 15 (street level).
- Wrap in a `Card` to match the existing summary card styling.

## Files affected

- `lib/nearby.dart` — add new `_contextMap(position)` widget method and call
  it from `_buildResults`.

## Backend changes

None.

## Privacy considerations

- Only the user's own position is plotted — they already know where they
  are.
- The 540 m circle's centre reveals where they scanned, but this is visible
  to the user running the scan, not to others.
- No postbox data is shown.

## Open questions

- Should the map persist after refresh, or re-centre each time?
- Should we cache tiles to avoid re-downloading on every refresh?
- What happens if the user's position changed significantly between the
  scan request and when the map renders (unlikely but possible)?
