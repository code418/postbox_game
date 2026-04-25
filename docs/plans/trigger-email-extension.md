# Plan — Transactional email via "Trigger Email" extension

- **Status:** Proposed
- **Effort:** Small
- **Firebase services:** Extensions (`firebase/firestore-send-email`), Firestore, SMTP provider (e.g. SendGrid, Postmark, Mailgun)

## Overview

Add transactional email for account events and recap digests using the official Trigger Email extension. The extension watches a Firestore `mail` collection and sends messages via configured SMTP.

## Email types (initial)

1. **Friend request / added** — "You've been added as a friend by {X}".
2. **Weekly recap digest** — mirrors in-app recap, opt-in only.
3. **Challenge invite** — when the challenges plan ships.
4. **Account deletion confirmation** — legal/receipt for deletion.

## Firestore schema

- `mail/{autoId}` = `{ to: string | string[], template: { name, data }, delivery? }`.
- Templates stored under `mailTemplates/{name}` with Handlebars-compatible body/subject.

## Templates

- `friend_added` — James-voiced subject, plain-text + HTML variants.
- `weekly_recap` — references a rendered stat block.
- `challenge_invite` — call-to-action deep link (Hosting deep-link plan).
- `account_deleted` — receipt + links to privacy policy.

## Cloud Functions hooks

- `onFriendAdded` (already exists for FCM) — additionally write a `mail/` doc when `user.emailNotifications.friendAdded !== false`.
- Weekly recap function writes mail docs in the same pass as generating recap docs.

## Provider

- SendGrid free tier (~100/day) is enough for beta; swap to Postmark or SES for higher volume.
- Store SMTP credentials via `firebase functions:secrets:set`, never in repo.

## Compliance

- Every email has an unsubscribe link that deep-links to notification settings.
- Respect `users/{uid}/emailPrefs` (new field).
- Honour GDPR: on account deletion, remove pending mail docs for that user first.

## Rollout

- Install in staging, send test emails to internal addresses.
- Enable per-type: start with `account_deleted` (lowest volume), then `friend_added`, then digests.

## Risks

- Email deliverability — configure SPF/DKIM/DMARC for the sending domain.
- Spam complaints → reputation loss; err on the side of opt-in.

## Testing

- Integration test that writes a mail doc and verifies extension delivery path (via provider sandbox).
