# F2 — Interactive tutorial

- **Status:** Proposed
- **Screen:** Intro / onboarding (`lib/intro.dart`)
- **Effort:** Medium
- **Privacy:** Compatible

## Overview

Add a new intro step where the map is centred on a well-known UK location
(Trafalgar Square) with a fictional postbox marker. Walks the user
through a simulated find-and-claim without requiring real location
permission. Great for users on devices without GPS or indoors at
first-launch.

## User flow

1. Intro advances to a new **Try finding a postbox** step.
2. Map centres on Trafalgar Square with a red postbox pin (`postboxMarker`).
3. Postman James says: "See that red pin? That's a postbox. Tap it."
4. User taps the pin. A simulated quiz appears with three cipher options.
5. User selects one; James gives feedback ("Correct!" / "Not quite, try
   again").
6. On success, confetti fires, map shows a "claimed" checkmark on the
   pin, and the user advances to the next intro step.

## Technical approach

- Hard-coded `LatLng(51.5080, -0.1281)` centre.
- One `postboxMarker` with `cipher: 'VR'` (Victorian — a nice rare tease).
- Tap handler triggers a mock quiz dialog reusing the existing quiz UI
  from `claim.dart`.
- All interaction is local — no Cloud Function calls.

## Files affected

- `lib/intro.dart` — new step.
- `lib/widgets/intro_tutorial_map.dart` — new widget.
- Possibly extract the quiz UI from `claim.dart` into
  `lib/widgets/cipher_quiz.dart` for reuse.

## Backend changes

None.

## Privacy considerations

- No real location used.
- No data uploaded.
- Safe for first-run before permission grants.

## Open questions

- Should the tutorial be gated on "never completed" or always available
  via the replay?
- How many cipher options in the mock quiz? Claim uses 4.
- Is Trafalgar Square too generic? Consider rotating between a few iconic
  spots (Edinburgh Waverley, Cardiff Castle, Belfast City Hall).
