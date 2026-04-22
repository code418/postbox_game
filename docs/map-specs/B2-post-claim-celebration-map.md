# B2 — Post-claim celebration map

- **Status:** Proposed
- **Screen:** Claim (`lib/claim.dart`)
- **Effort:** Medium
- **Privacy:** Compatible (post-claim only) — requires backend change

## Overview

After a successful claim, the existing confetti celebration gains a small
map showing the claimed postbox location as a pin next to the user.
Confetti particles emanate from the pin. Reinforces the sense of
"accomplishment at a place" and anchors the claim as a memory.

## User flow

1. User successfully claims.
2. The existing `_buildClaimed` success screen renders with confetti.
3. Below the points badge, a map card slides in from the bottom (300 ms
   animation) showing the user's position and a postbox pin at the claimed
   location, coloured by the cipher's `MonarchInfo.colors`.
4. The cipher name appears below the map: "Victoria (1840–1901)".

## Technical approach

- Extend the `startScoring` Cloud Function to return `{ lat, lng, cipher }`
  per claimed postbox in the response.
- In `_buildClaimed`, render a `PostboxMap` with:
  - `userPositionMarker(userPos)` for the user.
  - `postboxMarker(boxPos, cipher: cipher)` for each claimed postbox.
  - `fitBoundsOptions` to include both markers with padding.
- Trigger `ConfettiController` from the pin position using a
  `RepaintBoundary` + coordinate conversion, or keep the existing
  full-screen confetti and just show the map.

## Files affected

- `functions/src/_getPoints.ts` / `functions/src/index.ts` —
  `startScoring` response type to include claimed postbox positions.
- `functions/firestore.rules` — no change (server-side read).
- `lib/claim.dart` — extend `_buildClaimed` to render the celebration map.

## Backend changes

`startScoring` response gains a `claimedPostboxes: [{ id, lat, lng,
cipher }]` array. The server already has these fields during the claim
lookup (`_lookupPostboxes.ts`).

## Privacy considerations

- The user is physically standing next to the postbox (within 30 m) to
  claim it, so revealing its exact lat/lng does not give them information
  they could not already derive.
- The map is only shown **after** a successful claim, so this cannot be
  used to discover unclaimed postboxes.
- **Does not violate the "no looking up locations in advance" rule** because
  the box has already been claimed by the time it is revealed.

## Open questions

- Should the map persist in the user's claim history (see H1)?
- Accessibility: announce the claim location via semantic label.
- If multiple postboxes were claimed in one scan, how to lay them out?
