# J2 — Postman James as user marker

- **Status:** Proposed
- **Screen:** Any map-enabled screen
- **Effort:** Small
- **Privacy:** Compatible

## Overview

Replace the standard red-dot user-position marker with a custom marker
showing Postman James (the `PostmanJamesSvg` widget, with head-bob
animation). Reinforces the character-driven identity and makes the map
feel warm and distinctly "postbox game".

## User flow

1. On any map screen, the user's position is shown as a tiny animated
   Postman James figure instead of a generic blue dot.
2. James faces the direction of movement (if heading data is available
   via `flutter_compass`).
3. When the user is stationary for >5 seconds, James shrugs or looks
   around idly.

## Technical approach

- Extend `lib/widgets/postbox_marker.dart` with a `jamesUserMarker()`
  helper that wraps `PostmanJamesSvg` in a `Marker`.
- `PostmanJamesSvg` already has head-bob animation; wrap in a
  `RotationTransition` that takes compass heading for facing direction.
- Default size 48 × 64 (taller than wide — James is a person, not a
  circle).

## Files affected

- `lib/widgets/postbox_marker.dart` — add `jamesUserMarker()`.
- Each map screen — swap `userPositionMarker` for `jamesUserMarker`
  behind a feature flag or preference.

## Backend changes

None.

## Privacy considerations

- None.

## Open questions

- Performance: `PostmanJamesSvg` has multiple animated overlays. Is it
  fine to have it constantly rendering on every map? Likely yes —
  the animations are lightweight — but profile.
- If the map zooms out, James becomes too small to read. At what zoom
  level do we fall back to a plain dot?
- Accessibility: screen-reader label "Your position (Postman James)".
