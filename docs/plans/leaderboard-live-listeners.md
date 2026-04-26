# Plan — Live leaderboard listeners with overtake animations

- **Status:** Proposed
- **Effort:** Small
- **Firebase services:** Firestore (realtime listeners), FCM (already wired)
- **Touches:** `lib/leaderboard_screen.dart`, new `lib/widgets/leaderboard_row.dart`

## Overview

Replace the current `FutureBuilder` fetch of `leaderboards/{period}/entries` with a `StreamBuilder` over a live snapshot query. When a row's rank changes while the screen is visible, animate it (position tween + brief highlight). Overtake FCM already exists server-side; this is purely a client-side enhancement.

## User flow

1. User opens Leaderboard tab.
2. List renders instantly from cache, then live-updates as backend writes land.
3. If the current user or a friend moves up, their row slides into the new position with a gold flash for ~1.2 s.

## Technical approach

- Switch `_PeriodList` and `_FriendsPeriodList` to `collectionSnapshots()`.
- Wrap the list in `AnimatedList` keyed by `uid`. Diff the previous vs current ordering to drive insert/remove/move animations.
- Reuse `flutter_animate` (already in the project) for the highlight flash.
- Keep pagination limit (top 50) to cap listener cost.

## Backend

No changes. `startScoring` already writes deltas.

## Cost

Each open leaderboard = one active snapshot listener. Listener cost ≈ doc reads on change, not constant polling. Acceptable at expected scale; revisit if per-period docs exceed ~50 rows.

## Rollout

- Flag: `feature_live_leaderboard` in Remote Config.
- Default on after internal QA; no server-side migration needed.

## Risks

- Animation jitter on slow devices — provide a `reduceMotion` short-circuit via `MediaQuery.disableAnimations`.
- Snapshot storms if scoring writes rapidly; backend already coalesces via `startScoring`, so low risk.

## Testing

- Widget test: inject a `FakeFirebaseFirestore` and emit successive orderings; assert `AnimatedList` insert/remove hooks fire.
- Manual: two accounts claiming in parallel; verify the overtaking row animates and the overtaken friend's FCM fires.
