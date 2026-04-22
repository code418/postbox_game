# F3 — "Postboxes everywhere" demo

- **Status:** Proposed
- **Screen:** Intro / onboarding (`lib/intro.dart`)
- **Effort:** Small
- **Privacy:** Compatible (sample data only)

## Overview

A dramatic intro step showing a pre-loaded map with hundreds of postbox
pins across a sample UK region to communicate the density, ubiquity, and
excitement of the game. Uses sample data bundled with the app
(`test.json` or a redacted subset), not live queries.

## User flow

1. Intro advances to a **Postboxes everywhere** step.
2. Map opens zoomed to Greater London.
3. Hundreds of postbox pins pop in with a staggered animation (10 ms
   delay each, 3 seconds total).
4. Text overlay: "Over 100,000 postboxes across the UK. Let's find some."
5. Auto-advances after the animation, or user taps Continue.

## Technical approach

- Ship a sample dataset as an asset: `assets/intro_postboxes_sample.json`.
- Only 200–500 sample points (not the full 100K) to keep the asset
  small (~20 KB).
- Render as `Marker`s via `postboxMarker()`.
- Stagger entrance using `AnimationConfiguration` from
  `flutter_staggered_animations` (already a dependency).
- Use a marker clustering package if the pin count is too dense; start
  without clustering and evaluate.

## Files affected

- `assets/intro_postboxes_sample.json` — new asset.
- `pubspec.yaml` — add the asset path.
- `lib/intro.dart` — new step.
- `lib/widgets/intro_density_map.dart` — new widget.

## Backend changes

None.

## Privacy considerations

- Sample data is public OSM data — same as the app's live data.
- No personal information.
- Doesn't leak anything about real claimable postboxes because it's a
  pre-rendered demo.

## Open questions

- Which UK region looks most impressive? London is obvious but every
  user from Leeds will feel ignored. Consider user-location-dependent
  centring.
- Should the sample be dynamic (choose a region near the user) or
  always the same?
- The pins visually reveal OSM postbox locations — but OSM is already
  public data, so this doesn't violate the "no looking up locations"
  game rule (the issue is looking up locations for in-game claiming,
  not general OSM data).
