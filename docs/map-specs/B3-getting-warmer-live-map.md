# B3 — "Getting warmer" live map

- **Status:** Proposed (contentious)
- **Screen:** Claim (`lib/claim.dart`)
- **Effort:** Large
- **Privacy:** **VIOLATES GAME RULES** (naive implementation)

## Overview

A live-updating map during the searching state that visualises how close
the user is to the nearest unclaimed postbox. The naive form (show a
"hot zone" polygon) violates the rule against looking up postbox locations
in advance. A rule-compatible variant is proposed below.

## Rule-compatible variant: "heat pulse only"

Instead of showing a hot zone or direction, the map pulses the user's
radius circle with varying intensity based on how close the nearest
postbox is. The player feels warmth/cold but gets no directional or
positional information.

## User flow

1. User taps **Scan for postbox**.
2. Map shows user position with a 30 m circle.
3. As the user walks, the circle border pulses faster / redder when a
   postbox is closer (binned: very far / far / medium / close / in range).
4. No direction is given. No polygon or marker is shown.
5. When a postbox enters the 30 m range, the regular results flow fires.

## Technical approach (rule-compatible variant)

- New Cloud Function `nearestPostboxDistanceBin(lat, lng)` that returns
  only a bin number (0–4) — **never a direction or exact distance**.
- Client polls every 5–10 seconds while in the scan state.
- Client animates the circle border based on the bin.

## Technical approach (naive variant — NOT RECOMMENDED)

Show a polygon covering the area where a postbox exists. This is functionally
equivalent to a treasure map. Not compatible with game rules.

## Files affected

- `functions/src/index.ts` — new `nearestPostboxDistanceBin` callable.
- `functions/src/_lookupPostboxes.ts` — add nearest-distance helper.
- `lib/claim.dart` — extend searching state with polling + animation.

## Backend changes

New Cloud Function returning only a bin number. No lat/lng, no bearing.

## Privacy considerations

- The bin-only approach **does not** give directional information.
- Distance resolution is capped at 5 bins, so players cannot triangulate
  by moving and comparing readings.
- However, players can still triangulate with enough movement samples if
  the bins are too fine. Start with 3 bins (close / nearby / far) and only
  update on substantial movement (e.g. every 20 m walked).

## Open questions

- Does this still violate the spirit of the game? It gives a binary
  "something is here" signal that could trivialise exploration.
- Is the polling traffic cost-effective vs. the value added?
- **Strong recommendation:** decline this spec unless there is compelling
  user-research signal that claiming is too hard without a warmth hint.
