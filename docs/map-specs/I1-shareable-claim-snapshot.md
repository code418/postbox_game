# I1 — Shareable claim snapshot

- **Status:** Proposed
- **Screen:** Claim success (`lib/claim.dart`) or Profile (H1)
- **Effort:** Medium
- **Privacy:** Compatible (post-claim only) — depends on B2 being shipped

## Overview

Generate a branded static map image after a successful claim, showing
the claimed postbox's location with app branding, points earned, and
cipher name. User can share the image to social media or messaging
apps.

## User flow

1. After a successful claim, the success screen gains a **Share** button.
2. Tapping it generates an image capture of a prepared share card:
   - App logo at top
   - Map with a pin on the claimed postbox
   - "Found a Victorian postbox in Bristol — 7 points!"
   - Streak count
   - Postman James silhouette
3. `Share.share()` presents the OS share sheet with the image.

## Technical approach

- Build an off-screen `RepaintBoundary` containing the share card layout
  with `PostboxMap` inside.
- Capture via `boundary.toImage(pixelRatio: 3.0)` then
  `image.toByteData(format: ImageByteFormat.png)`.
- Use `share_plus` package to present the OS share sheet.
- Requires the claim response to include lat/lng (see B2).

## Files affected

- `pubspec.yaml` — add `share_plus` (maintained, battle-tested).
- `lib/claim.dart` — add Share button in `_buildClaimed`.
- `lib/widgets/share_card.dart` — new widget.

## Backend changes

None beyond B2 (claim response lat/lng).

## Privacy considerations

- User explicitly triggers sharing, so no passive data leak.
- Image contains the postbox location — but the user is sharing
  intentionally, and the box is already claimed.
- Warn users in onboarding not to share their home postbox if they claim
  it (privacy hygiene).

## Open questions

- Should the share card show the user's exact walking path from
  home / start? No — keep it to the single pin.
- Which social networks have reliable image-share support via the OS
  share sheet? All major ones via `share_plus`.
- Add a watermark / URL to encourage installs from the share?
