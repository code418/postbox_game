# Map Integration Specs

This directory contains one spec per proposed map feature, enabled by the
addition of `flutter_map` and `latlong2` to the app. Specs are brainstorming
documents — each is a standalone proposal, not a commitment to implement.

## Game-rule constraint

> **Looking up the location of unclaimed postboxes in advance is against the
> rules of the game.**

Any spec that would reveal unclaimed postbox positions to the client — even
imprecisely — is clearly flagged with `**Privacy: VIOLATES GAME RULES**` and
must not be implemented without explicit product sign-off.

## Preferred order of implementation

See [**IMPLEMENTATION_ORDER.md**](IMPLEMENTATION_ORDER.md) for a phased
roadmap, dependency graph, and cost / impact ranking.

## Index

### Nearby screen (`lib/nearby.dart`)
- [A1 — Sector heatmap overlay](A1-sector-heatmap-overlay.md)
- [A2 — "You Are Here" context map](A2-you-are-here-context-map.md)
- [A3 — Cipher distribution by sector](A3-cipher-distribution-by-sector.md)

### Claim screen (`lib/claim.dart`)
- [B1 — Claim-radius visualisation](B1-claim-radius-visualisation.md)
- [B2 — Post-claim celebration map](B2-post-claim-celebration-map.md)
- [B3 — "Getting warmer" live map](B3-getting-warmer-live-map.md)

### Leaderboard (`lib/leaderboard_screen.dart`)
- [C1 — Geographic coverage on Lifetime tab](C1-geographic-coverage-lifetime.md)
- [C2 — Regional leaderboards with map selector](C2-regional-leaderboards.md)
- [C3 — Friend location comparison map](C3-friend-location-comparison.md)

### Friends (`lib/friends_screen.dart`)
- [D1 — Friend's coverage map](D1-friends-coverage-map.md)
- [D2 — "Meet up" map](D2-meet-up-map.md)

### Settings (`lib/settings_screen.dart`)
- [E1 — Map style preference](E1-map-style-preference.md)
- [E2 — Home location marker](E2-home-location-marker.md)
- [E3 — Scan-radius visualisation](E3-scan-radius-visualisation.md)

### Intro / onboarding (`lib/intro.dart`)
- [F1 — Animated map zoom](F1-animated-map-zoom.md)
- [F2 — Interactive tutorial](F2-interactive-tutorial.md)
- [F3 — "Postboxes everywhere" demo](F3-postboxes-everywhere-demo.md)

### New dedicated Map tab
- [G1 — Full explore map](G1-full-explore-map.md)
- [G2 — Claimed postbox trail](G2-claimed-postbox-trail.md)
- [G3 — "Fill the map" gamification](G3-fill-the-map-gamification.md)

### Profile / statistics
- [H1 — Personal claim map](H1-personal-claim-map.md)
- [H2 — Streak map](H2-streak-map.md)
- [H3 — Rare-finds map](H3-rare-finds-map.md)

### Sharing & notifications
- [I1 — Shareable claim snapshot](I1-shareable-claim-snapshot.md)
- [I2 — "Postbox of the day" map card](I2-postbox-of-the-day-card.md)

### Postman James integration
- [J1 — Map commentary](J1-map-commentary.md)
- [J2 — James as user marker](J2-james-as-user-marker.md)

### UX & accessibility
- [K1 — Map / list toggle](K1-map-list-toggle.md)
- [K2 — Offline tile caching](K2-offline-tile-caching.md)

## Spec template

Each spec follows the same structure:

- **Status** — Proposed / In progress / Implemented / Declined
- **Screen** — Where this lives in the app
- **Effort** — Small / Medium / Large
- **Privacy** — Compatible / Backend change / Opt-in / VIOLATES GAME RULES
- **Overview** — One-paragraph summary
- **User flow** — What the player sees and does
- **Technical approach** — How to implement using `PostboxMap` and existing code
- **Files affected** — Paths that would change
- **Backend changes** — Cloud Function / Firestore rule changes required
- **Privacy considerations** — What data is exposed and how it is protected
- **Open questions** — Unresolved design decisions
