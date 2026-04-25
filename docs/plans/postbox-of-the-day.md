# Plan — Postbox of the Day

- **Status:** Proposed
- **Effort:** Medium
- **Firebase services:** Cloud Functions (scheduled), Firestore, FCM

## Overview

Each day, the backend picks a single postbox to be "Postbox of the Day" (POTD). Claiming POTD awards 2× points. Everyone gets a morning push (James-voiced teaser with a rough region hint) and in-app banner.

## Data model

- `postboxOfTheDay/{YYYY-MM-DD}` = `{ postboxId, monarch, regionOutcode, announcedAt, expiresAt }`.
- Optional `postboxOfTheDay/current` pointer doc updated atomically.
- `claims` entries gain an optional `bonusReason: "potd"` tag.

## Selection algorithm

- Scheduled Cloud Function `selectPostboxOfTheDay` runs at 06:00 London time.
- Weighted random pick favouring rarer monarchs but excluding those picked in the last 30 days (stored in `postboxOfTheDay/history`).
- Must have been claimed at least once historically (avoid dead locations).

## Notification

- Send to topic `rare_finds` or `potd` topic (created alongside this).
- Message: "James reckons something special is hiding around {OUTCODE}... Go have a peek."
- No exact coordinates in the push payload.

## Claim-path changes

- `startScoring` checks if the claimed postbox matches `postboxOfTheDay/current.postboxId` and applies the 2× multiplier.
- Records `bonusReason: "potd"` on the claim and emits an Analytics event `potd_claimed`.

## Client changes

- Home screen banner above the navigation bar when POTD is active and unclaimed by this user.
- Tapping the banner deep-links into Nearby with a James line: "Today's special is somewhere near here..."
- Use the existing `JamesController` to surface a bespoke line.

## Rollout

- Flag `feature_potd_enabled`.
- Soft launch: enable without 2× multiplier for a week to validate selection + notification; turn on multiplier in week 2.

## Risks

- Picking a postbox in an unpopulated area = nobody claims. Add a weight penalty for low-density regions using existing claim history.
- Push fatigue — respect `notificationPrefs` and quiet hours.

## Testing

- Unit test selection algorithm with a seeded RNG and fixture history.
- Integration test (firebase-functions-test) for the 2× multiplier path in `startScoring`.
