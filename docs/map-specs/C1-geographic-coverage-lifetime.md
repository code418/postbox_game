# C1 — Geographic coverage on Lifetime tab

- **Status:** Proposed
- **Screen:** Leaderboard (`lib/leaderboard_screen.dart`) — Lifetime tab
- **Effort:** Medium
- **Privacy:** Compatible (coarse aggregation) — requires backend change

## Overview

In the lifetime leaderboard, each row becomes expandable to reveal a map
showing the geographic spread of the user's claims — as low-resolution
geohash rectangles, not pins. Gives a "they've explored Edinburgh AND
Glasgow" feel without revealing specific postboxes.

## User flow

1. On the Lifetime tab, each user row has a new "expand" chevron.
2. Tapping it expands the row inline to show a UK-scale map (~250 px
   tall).
3. Map has grey rectangles for geohash cells where the user has at least
   one claim. Cell size is precision 4 (~20 km × 20 km) or precision 5
   (~5 km × 5 km), depending on the zoom level.
4. Darker rectangles mean more claims in that cell.
5. Collapsing the row removes the map to save memory.

## Technical approach

- New Firestore subcollection: `users/{uid}/coverage/{geohash4}` with
  `{ count: n }`. Updated server-side on each claim.
- New Cloud Function `getUserCoverage(uid)` returns an array of
  `{ geohash, count }`.
- Client renders one `Polygon` per geohash cell with `ngeohash`-decoded
  bounds.
- Use opacity scaling for `count` visualisation.

## Files affected

- `functions/src/startScoring.ts` — on claim, increment the geohash4
  coverage counter.
- `functions/src/index.ts` — new `getUserCoverage` callable.
- `firestore.rules` — allow users to read their own coverage; friends can
  read each other's coverage.
- `lib/leaderboard_screen.dart` — expandable row with coverage map.

## Backend changes

- New subcollection and aggregation logic.
- Backfill Cloud Function to populate coverage for existing claims.

## Privacy considerations

- Geohash 4 is ~20 km × 20 km — about the size of a small city. Shows
  "this user has been to Manchester" but not any specific street.
- Geohash 5 (~5 km) is finer but still privacy-preserving.
- Coverage is visible to the user themselves and opted-in friends only.
- **Does not reveal postbox locations** — only which large regions a user
  has been active in.

## Open questions

- Geohash precision: 4 or 5? Product decision.
- Should coverage be public on the leaderboard, or friends-only?
- Handle the case of users who have claimed in only one city — should
  the map auto-zoom to their coverage or always show the UK?
