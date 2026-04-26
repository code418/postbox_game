# Plan — Friend challenges (head-to-head)

- **Status:** Proposed
- **Effort:** Large
- **Firebase services:** Cloud Functions (callable + Firestore triggers), Firestore, FCM

## Overview

Let a user challenge a friend to a short-term contest ("First to 5 EVIIR boxes this week" / "Most claims in the next 48 h"). Winner earns a cosmetic badge. No real-world wagering.

## Data model

- `challenges/{id}` = `{ fromUid, toUid, type, target, goalValue, startAt, endAt, status, fromProgress, toProgress, winnerUid?, createdAt }`.
- `challenges/{id}/events/{eventId}` — append-only for auditability.
- `users/{uid}.badges[]` appended on win.

## Challenge types (initial)

- `first_to_n_rare` — first to claim N rare-tier boxes.
- `most_claims` — highest claim count in window.
- `longest_streak` — for 7-day challenges.

## Callables

- `createChallenge({ toUid, type, target, goalValue, durationHours })` — validates friendship, window <= 7 days, goal within allowed range.
- `acceptChallenge({ id })`, `declineChallenge({ id })`.
- `cancelChallenge({ id })` — before acceptance only.

## Progress tracking

- Firestore trigger `onClaimCreated` checks active challenges involving the claimant and updates `fromProgress` / `toProgress`.
- When progress hits goal or window expires, set `status=completed`, determine winner, write badge.

## Notifications

- FCM on invite, accept, mid-challenge overtake, and completion.
- Reuse `_notifications.ts` helpers.

## Client

- `lib/challenges_screen.dart` — list of active, invited, completed challenges.
- Compose flow from friend profile: "Challenge this friend" button.
- Badge display on profile page.

## Security

- Firestore rules: challenges are read-only to participants; writes via callable only.

## Rollout

- Flag `feature_challenges_enabled`.
- Internal testing first — small friend group.
- Cap concurrent active challenges per user at 3.

## Risks

- Abuse: spamming challenge invites. Rate-limit `createChallenge` to 5/day per user.
- Clock drift in claim timestamps near window boundaries — use server timestamps only.

## Testing

- Unit tests for progress calc across challenge types.
- Integration test: full lifecycle create → accept → progress → completion.
