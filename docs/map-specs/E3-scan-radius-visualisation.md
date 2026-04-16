# E3 — Scan-radius visualisation

- **Status:** Proposed
- **Screen:** Settings (`lib/settings_screen.dart`)
- **Effort:** Small
- **Privacy:** Compatible

## Overview

In settings, show a small map preview with the current nearby radius
(540 m) and claim radius (30 m) drawn as concentric circles around the
user's last-known position. Pairs nicely with the existing distance-unit
setting to help users understand the game's spatial scale.

## User flow

1. User opens Settings.
2. Below the existing **Distance units** tile, a new card appears
   titled **"Scan distances"**.
3. Inside, a non-interactive map shows two circles:
   - Outer: 540 m (labelled "Nearby scan")
   - Inner: 30 m (labelled "Claim range")
4. Labels show the current distance in the user's chosen unit.
5. Tapping expands to a full-screen map with additional annotations.

## Technical approach

- Use `PostboxMap` with two `CircleMarker`s via `scanRadiusCircle()`.
- Fixed zoom level that makes the 540 m circle ~60 % of the preview
  width.
- `InteractionOptions(flags: InteractiveFlag.none)` for the embedded
  preview; full interactivity in the expanded view.
- Reuses `AppPreferences.nearbyRadiusMeters` and `claimRadiusMeters`.

## Files affected

- `lib/settings_screen.dart` — new section.

## Backend changes

None.

## Privacy considerations

- Uses the user's own position, which they already know.
- No server interaction; purely cosmetic.

## Open questions

- Should the map use the user's current position or their home location
  (E2) if set?
- Is this useful enough to warrant tile downloads every time Settings
  opens? Consider caching.
