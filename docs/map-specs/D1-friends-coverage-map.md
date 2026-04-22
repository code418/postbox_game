# D1 — Friend's coverage map

- **Status:** Proposed
- **Screen:** Friends (`lib/friends_screen.dart`)
- **Effort:** Medium
- **Privacy:** Opt-in — requires backend change

## Overview

Tapping a friend in the friends list opens a detail view showing their
geohash coverage overlaid on a UK map. Reinforces friendly competition:
"you've explored London and I've explored Scotland — let's cover the
Midlands together."

## User flow

1. User opens the Friends tab.
2. Taps a friend's card (which currently just shows a name + avatar).
3. A detail screen slides up with the friend's display name, rank summary,
   and a UK map showing their coverage as geohash rectangles (same
   rendering as C1).
4. User can toggle to see their own coverage overlaid for direct
   comparison (two colours: red = friend, gold = you).
5. Back arrow returns to the friends list.

## Technical approach

- Reuse the coverage data model from C1 (`users/{uid}/coverage`).
- Opt-in sharing via the Settings toggle introduced in C3.
- Detail screen is a new `FriendDetailScreen` widget navigated to via
  `MaterialPageRoute`.

## Files affected

- `lib/friends_screen.dart` — wrap friend cards with `InkWell` navigation.
- `lib/friend_detail_screen.dart` — new screen.
- `functions/src/index.ts` — endpoint for reading a friend's coverage
  (protected by the share flag).
- `firestore.rules` — allow reads from friends only when `shareCoverage`
  is true.

## Backend changes

Shared with C1 and C3. No additional backend work beyond those.

## Privacy considerations

- Coverage is opt-in via a Settings toggle.
- Only geohash-4 or -5 precision (city to neighbourhood level), never
  postbox positions.
- Viewer must be in the friend's friends list to see the coverage.

## Open questions

- Should the friend detail screen also show their recent claims feed
  (cipher types, dates — no locations)?
- Should it be a modal bottom sheet or a full page?
- How should the UI communicate when a friend has not opted in to sharing?
