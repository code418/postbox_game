# Plan — Realtime Database presence for online friends

- **Status:** Proposed
- **Effort:** Small
- **Firebase services:** Realtime Database, Authentication
- **Touches:** `lib/friends_screen.dart`, `lib/user_profile_page.dart`, new `lib/services/presence_service.dart`

## Overview

Show a small "online now" dot on friend cards and the profile page. Presence is ephemeral and high-churn, which makes Realtime Database (RTDB) `onDisconnect` a better fit than Firestore for cost and latency.

## User flow

1. User opens the Friends tab.
2. Friends who have the app in the foreground show a green dot next to their avatar; recently-active (<5 min background) show a grey dot.
3. Profile page mirrors the status in the header.

## Technical approach

- Add RTDB to the Firebase project (new database in the same region as Firestore, e.g. `europe-west1`).
- On auth state change to signed-in, `PresenceService` writes `/status/{uid}` = `{ state: "online", lastChanged: ServerValue.TIMESTAMP }` and registers `onDisconnect().set({ state: "offline", lastChanged: ServerValue.TIMESTAMP })`.
- On `AppLifecycleState.paused` set `state: "background"`; on `resumed` set `state: "online"`.
- Mirror to Firestore only on transitions via an RTDB-triggered Cloud Function (`functions/src/presence.ts` → `onValueWritten`), so Firestore-only clients can still read a coarse status.
- Friends screen subscribes directly to `/status/{friendUid}` refs for each friend in a batched `ValueEventListener`.

## Data model

- RTDB `/status/{uid}`: `{ state: "online" | "background" | "offline", lastChanged: number }`.
- Optional Firestore mirror at `users/{uid}.presence` for non-listening contexts.

## Security rules

- RTDB rules: `/status/{uid}` write-restricted to `auth.uid == $uid`; read restricted to signed-in users who are friends (enforce via Cloud Function mirror if RTDB rule complexity grows).

## Rollout

- Gate behind Remote Config flag `feature_presence_enabled` (default false).
- Ship dot UI behind the flag; enable for internal testers first.

## Risks

- RTDB adds a second datastore — keep logic thin, treat Firestore as source of truth.
- `onDisconnect` can fire late on mobile networks; treat "offline" as eventually consistent.
- Privacy: hide presence if the user toggles a "invisible mode" preference in settings.

## Testing

- Unit test `PresenceService` lifecycle transitions with a fake RTDB.
- Manual two-device test: sign in on both, kill one, verify the other sees offline within ~30 s.
