# D2 — "Meet up" map

- **Status:** Proposed
- **Screen:** Friends (`lib/friends_screen.dart`) — new "Meet up" mode
- **Effort:** Large
- **Privacy:** Opt-in, session-scoped — requires backend change

## Overview

Two friends who are out playing at the same time can opt into a shared
live-position map so they can find each other and play together. No
postbox data is shown — this is purely a social location-sharing feature.

## User flow

1. User A opens a friend's detail page (see D1) and taps **"Meet up"**.
2. User A chooses a duration (15 / 30 / 60 minutes).
3. User B gets a push notification and taps to accept.
4. Both users see a map with two moving dots: their positions (updating
   every 30 s while the session is active).
5. Distance between them is shown textually: "1.2 km apart".
6. Either user can end the session early; it auto-ends after the chosen
   duration.
7. After the session ends, positions are deleted from the server.

## Technical approach

- New Firestore collection: `meetup_sessions/{sessionId}` with member UIDs,
  expiry timestamp, and a `positions/{uid}` subcollection for live
  coordinates.
- Client writes position updates while in the session (throttled to every
  30 s and every 20 m moved, whichever is later).
- Cloud Function cron cleans up expired sessions.
- Client subscribes via `onSnapshot` for real-time dot movement.
- Use FCM for the "X wants to meet up" push notification.

## Files affected

- `functions/src/meetup.ts` — new file.
- `functions/src/index.ts` — export new functions.
- `firestore.rules` — strict access: members only, auto-expire.
- `lib/friend_detail_screen.dart` — "Meet up" button.
- `lib/meetup_screen.dart` — new map screen.
- `lib/meetup_service.dart` — new service for position updates.

## Backend changes

- New session collection and rules.
- FCM push notification flow.
- Cron cleanup for expired sessions.

## Privacy considerations

- Strict opt-in per session (no passive sharing).
- Time-boxed: positions auto-delete after the session ends.
- Both users can end the session instantly.
- Position updates respect OS-level "precise location" permissions.
- No postbox data — this is social only.
- **Does not violate the game rules** because no postbox positions are
  shared.

## Open questions

- Battery impact of continuous location updates — document in spec.
- What happens if one user loses connectivity? Show a "stale" indicator?
- Should the session show an ETA to walk toward each other?
- Is a 30 s update interval fine-grained enough for a meet-up?
