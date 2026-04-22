# H1 — Personal claim map

- **Status:** Proposed
- **Screen:** New Profile screen (accessible from Settings or a Profile tab)
- **Effort:** Medium
- **Privacy:** Compatible (user's own data) — requires backend change

## Overview

A full-screen map showing every postbox the user has ever claimed, with
pins coloured by cipher and filter toggles per cipher type. A quick way
for the player to relive their hunting history visually.

## User flow

1. User opens **Profile** (or Settings → My claims).
2. Full-screen map with every claimed postbox as a cipher-coloured pin.
3. Filter chips across the top: All / EIIR / VR / CIIIR / ... tapping a
   chip toggles visibility for that cipher.
4. Tapping a pin shows date, cipher, points, streak context.
5. Summary card at bottom: total claims, unique postboxes, distinct
   ciphers.
6. Share button (see I1) to post a screenshot.

## Technical approach

- Reuse the claim-history backend from G2.
- `FilterChip` widgets above the map for cipher filtering.
- Local state for filters (no persistence needed).
- Use `fitBounds` to zoom to the user's claim footprint on open.

## Files affected

- `lib/profile_screen.dart` — new screen.
- `lib/widgets/cipher_filter_chips.dart` — reusable filter bar.
- Shares backend with G2.

## Backend changes

Shared with G2.

## Privacy considerations

- User's own data only.
- No sharing unless explicitly triggered (I1).
- **Does not violate game rules** — all locations shown are postboxes
  the user has already claimed.

## Open questions

- Should the screen be a new tab or accessible only via Settings?
- How to handle pagination if the user has thousands of claims? Load
  all as polygons first and progressively add pins.
- Should the filter state be remembered across sessions?
