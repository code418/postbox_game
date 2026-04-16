# Preferred order of implementation

Not every spec should be built, and some depend on others. This document
recommends the sequence, grouped into phases that can each ship
independently. Earlier phases are lowest-risk and deliver the most value
per hour.

## Ordering principles

1. **Respect the game rule first.** Anything that reveals unclaimed
   postbox positions stays blocked. G1's only acceptable variants are
   covered by other specs, so G1 itself can be declined.
2. **Client-only before backend-dependent.** Specs that need no Cloud
   Function changes ship faster and with less risk.
3. **Build shared foundations early.** The claim-history pipeline (G2)
   unlocks H1, H2, H3, I1 — so it goes before them.
4. **Prove the pattern on one screen, then replicate.** A2 ("You Are
   Here" on Nearby) validates `PostboxMap` for the whole team before
   rolling maps out elsewhere.
5. **Cosmetic polish last.** J1/J2 and K1 are delightful but have zero
   gameplay impact.

## Phase 0 — Foundation (already done on this branch)

- `pubspec.yaml` adds `flutter_map` and `latlong2`.
- `lib/widgets/postbox_map.dart` reusable themed widget.
- `lib/widgets/postbox_marker.dart` themed marker helper.
- This spec pack.

## Phase 1 — Prove the widget, low-risk value (client-only)

Goal: ship something visible in 1–2 sprints; validate `PostboxMap` and
the OSM tile provider in production.

1. [**A2** — "You Are Here" context map](A2-you-are-here-context-map.md)
   — simplest map on the most-used screen.
2. [**B1** — Claim-radius visualisation](B1-claim-radius-visualisation.md)
   — same pattern on the claim screen.
3. [**E3** — Scan-radius visualisation in Settings](E3-scan-radius-visualisation.md)
   — reuses the same circles.
4. [**K1** — Map / list toggle](K1-map-list-toggle.md) — add the
   pattern as soon as users can switch between views.

After Phase 1, decide whether to continue based on engagement
telemetry. The Phase-1 specs are self-contained and can be reverted
cheaply if maps don't resonate.

## Phase 2 — Onboarding & polish (client-only)

Goal: improve first-launch wow-factor and overall feel.

5. [**F1** — Animated map zoom in Intro](F1-animated-map-zoom.md) —
   big wow-factor for new users.
6. [**F3** — "Postboxes everywhere" demo](F3-postboxes-everywhere-demo.md)
   — sample-data density for excitement.
7. [**E1** — Map style preference](E1-map-style-preference.md) —
   supports a future switch to a paid tile provider.
8. [**J2** — James as user marker](J2-james-as-user-marker.md) —
   reinforces the character identity on every map.
9. [**J1** — James map commentary](J1-map-commentary.md) — layer on
   once maps exist in enough places.

## Phase 3 — Richer nearby experience (client-only)

Goal: deepen the Nearby screen without changing the backend.

10. [**A1** — Sector heatmap overlay](A1-sector-heatmap-overlay.md) —
    uses existing compass data only.
11. [**E2** — Home location marker](E2-home-location-marker.md) —
    local-only storage; useful fallback centre for all maps.

## Phase 4 — Claim history pipeline (backend)

Goal: unlock the "my journey" group of features. This is the biggest
backend investment of the roadmap.

12. [**B2** — Post-claim celebration map](B2-post-claim-celebration-map.md)
    — the first backend change; adds `{lat, lng, cipher}` to the claim
    response.
13. [**G2** — Claimed postbox trail](G2-claimed-postbox-trail.md) —
    persists and exposes claim history with locations.
14. [**H1** — Personal claim map](H1-personal-claim-map.md) — uses the
    G2 pipeline.
15. [**I1** — Shareable claim snapshot](I1-shareable-claim-snapshot.md)
    — requires B2 at minimum; H1 is a better source of shareable cards.
16. [**H3** — Rare-finds map](H3-rare-finds-map.md) — a filter over H1.
17. [**H2** — Streak map](H2-streak-map.md) — date-range filter over
    the same pipeline.

## Phase 5 — Social & coverage (backend)

Goal: leverage friendship and coverage data for longer-term engagement.
Requires the `users/{uid}/coverage` subcollection and backfill.

18. [**C1** — Geographic coverage on Lifetime tab](C1-geographic-coverage-lifetime.md)
    — first use of the coverage subcollection.
19. [**D1** — Friend's coverage map](D1-friends-coverage-map.md) —
    adds friend-scoped reads.
20. [**G3** — Fill the map gamification](G3-fill-the-map-gamification.md)
    — polish over C1's coverage data.
21. [**C3** — Friend location comparison map](C3-friend-location-comparison.md)
    — extends D1 onto the leaderboard tab.

## Phase 6 — Ambitious / optional

These are large, open-question-heavy, or raise game-rule concerns.
Evaluate individually based on user research.

22. [**C2** — Regional leaderboards](C2-regional-leaderboards.md) —
    requires a region field on every postbox and a new leaderboard
    partition; high effort.
23. [**K2** — Offline tile caching](K2-offline-tile-caching.md) —
    ship only after switching to a paid tile provider that permits
    bulk download.
24. [**D2** — Meet-up map](D2-meet-up-map.md) — live location sharing,
    requires FCM, expiry logic, careful privacy UX.
25. [**I2** — Postbox of the day card](I2-postbox-of-the-day-card.md)
    — Variant A only (text-only, no map); skip other variants.
26. [**A3** — Cipher distribution by sector](A3-cipher-distribution-by-sector.md)
    — check with product whether per-cipher-per-sector is still within
    the "fuzzy" spirit.

## Explicitly declined (for now)

- [**G1** — Full explore map](G1-full-explore-map.md) — any variant
  that shows unclaimed postbox markers violates the game rule. The
  acceptable Variant E is just a restatement of A1 + A2. Decline.
- [**B3** — "Getting warmer" live map](B3-getting-warmer-live-map.md)
  — even the bin-only variant risks enabling triangulation. Decline
  unless user research specifically demands a warmth hint.
- [**I2** — Postbox of the day](I2-postbox-of-the-day-card.md) in any
  variant that directs players to a specific unclaimed box.

## Dependency graph (simplified)

```
Phase 0 (foundation)
    │
    ├── Phase 1: A2, B1, E3, K1  (standalone)
    │
    ├── Phase 2: F1, F3, E1, J2, J1  (standalone)
    │
    ├── Phase 3: A1, E2  (standalone)
    │
    ├── Phase 4: B2 ──► G2 ──► H1 ──► I1
    │                     ├──► H2
    │                     └──► H3
    │
    └── Phase 5: C1 ──► D1 ──► C3
                  └──► G3
```

## Cost / impact snapshot

| Spec | Effort | Expected value | Priority |
|------|--------|----------------|----------|
| A2   | S      | High           | ★★★      |
| B1   | S      | High           | ★★★      |
| E3   | S      | Low-Med        | ★★       |
| K1   | S      | Med (accessibility) | ★★★ |
| F1   | M      | High           | ★★★      |
| F3   | S      | Med            | ★★       |
| E1   | S      | Med            | ★★       |
| J2   | S      | High (identity) | ★★★     |
| J1   | S      | Med            | ★★       |
| A1   | M      | Med            | ★★       |
| E2   | S      | Low            | ★        |
| B2   | M      | High           | ★★★      |
| G2   | M      | High           | ★★★      |
| H1   | M      | High           | ★★★      |
| I1   | M      | Med            | ★★       |
| H3   | S      | Med            | ★★       |
| H2   | S      | Med            | ★★       |
| C1   | M      | Med            | ★★       |
| D1   | M      | Med            | ★★       |
| G3   | L      | Med-High       | ★★       |
| C3   | M      | Low-Med        | ★        |
| C2   | L      | Med            | ★        |
| K2   | M      | Low            | ★        |
| D2   | L      | Low            | ★        |
| A3   | M      | Low            | ★        |
| G1   | —      | —              | declined |
| B3   | —      | —              | declined |
| I2   | —      | —              | declined (except text-only Variant A) |
