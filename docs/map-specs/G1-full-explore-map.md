# G1 — Full explore map

- **Status:** Proposed — **conflicts with game rules**
- **Screen:** New 5th tab in `lib/home.dart` `NavigationBar`
- **Effort:** Large
- **Privacy:** **VIOLATES GAME RULES** (any variant that shows unclaimed
  postboxes, even imprecisely)

## Overview

A dedicated full-screen map tab showing postbox markers within the user's
viewport. **This is the most visible map feature and the most
rule-breaking one** — showing any unclaimed postbox markers contradicts
the "no looking up locations in advance" rule, regardless of how
imprecise the positioning is.

## Why this spec exists

Because a dedicated map tab is often the first thing users expect from a
location-based app, we need an explicit decision and documented
rationale for why we are **not** shipping it in the obvious form.

## Variants considered

### Variant A — Accurate markers (NOT ACCEPTABLE)
Pins at real postbox positions. Straightforwardly breaks the game.

### Variant B — Jittered markers (NOT ACCEPTABLE)
Pins at positions offset by a random 10–30 m. Still lets users
triangulate to within easy walking distance. Breaks the game.

### Variant C — Snapped-to-grid markers (NOT ACCEPTABLE)
Pins snapped to a 50–100 m grid. Still directly directs players to the
postbox. Breaks the game.

### Variant D — Claimed postboxes only (ACCEPTABLE)
A full-screen map showing **only postboxes the current user has already
claimed**, i.e. the same scope as H1 "Personal claim map". Acceptable
because the user has already been there. This variant duplicates H1, so
we'd skip it if H1 is shipped.

### Variant E — No postbox markers at all (ACCEPTABLE)
A full-screen map showing only the user's position and the 540 m / 30 m
radii, plus the fuzzy sector heatmap (A1). Acts as an
"explore-near-you" mode without revealing anything new. Essentially
A1 + A2 promoted to a full-screen tab.

## Recommendation

- **Do NOT** implement Variants A, B, or C.
- **Do** consider Variant E (rebrand as "Radar") if user research shows
  a map tab is desired.
- **Otherwise**, cover the same need via specs A1, A2, and H1 without
  adding a new tab.

## Files affected (if Variant E is built)

- `lib/home.dart` — add 5th tab.
- `lib/radar_screen.dart` — new full-screen map using `PostboxMap`.

## Backend changes

None for Variant E.

## Privacy considerations

- **Variants A / B / C are blocked on game-rule grounds.**
- Variant E exposes no postbox data.

## Open questions

- Product decision: do we want a map tab at all?
- If yes, which variant?
- Does a map tab make the navigation bar too crowded (5 tabs is the
  recommended max)?
