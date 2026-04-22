# B1 — Claim-radius visualisation

- **Status:** Proposed
- **Screen:** Claim (`lib/claim.dart`)
- **Effort:** Small
- **Privacy:** Compatible

## Overview

During and after a claim scan, show a small map with the user's position
surrounded by a 30 m radius circle. Makes the "you must be standing right
next to a postbox" rule visually obvious and reassures the user that GPS
drift within a small area is still in range.

## User flow

1. User taps **Scan for postbox** on the claim screen.
2. While searching, a map card renders with the user centred and a pulsing
   30 m red circle.
3. If postboxes are found, the map stays visible with the circle in a
   success colour (gold border).
4. If no postboxes found, the map shows the circle in a neutral grey, with
   text "Move to a new spot and try again."

## Technical approach

- Use `PostboxMap` with `interactionOptions: InteractionOptions(flags:
  InteractiveFlag.none)`.
- Pass `AppPreferences.claimRadiusMeters` (30.0) to `scanRadiusCircle`.
- For the pulsing effect, wrap the map in an `AnimationController` and
  animate the circle's `borderStrokeWidth` or `color` alpha.
- Use `userPositionMarker(center)` for the user.

## Files affected

- `lib/claim.dart` — add `_claimRadiusMap(position)` widget, call from
  `_buildSearching`, `_buildResults`, `_buildEmpty`.

## Backend changes

None.

## Privacy considerations

- Only the user's position and the 30 m circle are shown — no postbox data.
- The user already knows where they are, so nothing new is revealed.

## Open questions

- Should the pulse animation be configurable (respect reduced-motion
  accessibility settings)?
- What tile zoom level works best for a 30 m circle? Likely 18 or 19.
- Should the circle remain after a successful claim, or fade out to reveal
  the confetti animation?
