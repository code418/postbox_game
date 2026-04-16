# F1 — Animated map zoom

- **Status:** Proposed
- **Screen:** Intro / onboarding (`lib/intro.dart`)
- **Effort:** Medium
- **Privacy:** Compatible

## Overview

Replace the static overview icons on the "How it works" intro step with
an animated map sequence: start zoomed out over the UK, zoom into the
user's current city, then to street level with a 540 m radius circle
appearing. Teaches the scan concept visually and anchors the game in
familiar geography.

## User flow

1. During first-run intro (or "Replay intro" from settings), user
   advances to the **How it works** step.
2. A map fills the top half of the screen, starting zoomed to fit the
   whole of the UK.
3. Over 3 seconds, the map pans and zooms into the user's nearest city
   (falls back to London if no location permission).
4. Over 2 more seconds, it zooms further to street level.
5. A red 540 m circle fades in, with a label "Your scan area".
6. Postman James text below: "Right then — this is the area we'll sweep
   for postboxes."
7. User can tap "Skip" to stop the animation and continue.

## Technical approach

- Use `MapController.moveAndRotate` inside an `AnimationController`.
- Sequence of easing tweens for latitude, longitude, and zoom.
- Fade in the `CircleMarker` via `AnimatedOpacity`.
- If `getPosition()` fails, fall back to Trafalgar Square (51.5074 N,
  0.1278 W).
- Respect `MediaQuery.of(context).disableAnimations` — jump to final
  state instantly if reduced-motion is enabled.

## Files affected

- `lib/intro.dart` — replace `_buildOverview` step with the new animated
  map widget.
- `lib/widgets/intro_map_animation.dart` — new widget.

## Backend changes

None.

## Privacy considerations

- Uses only the user's own position.
- Graceful fallback if permission denied.
- Does not reveal any postbox data.

## Open questions

- Should we wait for location permission before showing the animation,
  or start with the fallback and re-centre if permission is granted?
- What's the minimum network dependency? Can we ship static tiles for
  the UK-scale first frame to avoid a slow intro on poor connections?
- Accessibility: provide a text alternative describing the animation for
  screen-reader users.
