# H3 — Rare-finds map

- **Status:** Proposed
- **Screen:** Profile screen (filtered view)
- **Effort:** Small (given H1 exists)
- **Privacy:** Compatible (user's own data) — requires backend change

## Overview

A filtered view of the personal claim map (H1) showing only rare and
historic cipher claims — VR, EVIIR, EVIIIR, CIIIR. Celebrates the
player's most impressive finds with a "trophy case" feel.

## User flow

1. User opens Profile → **Rare finds**.
2. Full-screen map with only rare/historic cipher pins.
3. Each pin uses a gold star variant of `postboxMarker` (matching the
   rare-cipher treatment in `nearby.dart:464-483`).
4. Summary card: "You've found 3 Victorian and 1 Edward VIII postboxes.
   Only 9 players in the country have all three!"
5. Empty state: "No rare finds yet. Victoria postboxes are often near
   historic town centres — go hunting!"

## Technical approach

- Same data pipeline as H1 with a server-side or client-side filter on
  `MonarchInfo.rareCiphers ∪ MonarchInfo.historicCiphers`.
- "Only N players in the country" stat would require a new Cloud
  Function computing the national rank per cipher.

## Files affected

- `lib/profile_screen.dart` — add a rare-finds section / subpage.
- Shares backend with H1 / G2.
- `functions/src/index.ts` — optional new `getRareCipherRank` callable.

## Backend changes

- Optional: cipher-rank Cloud Function for social-proof stats.
- Otherwise shares with H1.

## Privacy considerations

- User's own finds.
- Aggregated rank stats ("Nth player") reveal nothing personal about
  others.

## Open questions

- Should we gamify further with "achievement unlocked" popups when the
  user finds their first of a rare cipher?
- Rare cipher colour-coding: stick with `MonarchInfo.colors` or use
  gold for all rare finds (consistent "trophy" feel)?
