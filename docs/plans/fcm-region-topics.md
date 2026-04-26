# Plan — FCM topics per region and monarch-era

- **Status:** Proposed
- **Effort:** Small
- **Firebase services:** Cloud Messaging (topics), Cloud Functions

## Overview

Enable broadcast-style notifications without maintaining per-user subscription lists. Topics let the backend fan-out "A rare EVIIIR box was claimed near you" style alerts to thousands of users cheaply.

## Topic taxonomy

- `region_{outcode}` — UK postcode outcode (e.g. `region_BS1`). Derived from last-known user coarse location.
- `monarch_{code}` — `EIIR`, `GR`, `GVR`, `GVIR`, `VR`, `EVIIR`, `CIIIR`, `EVIIIR`, `SCOTTISH_CROWN`.
- `rare_finds` — shared alert for EVIIIR / EVIIR claims anywhere in UK.

## Subscription flow

1. On login, client subscribes to `monarch_*` for monarchs it's opted into (default: all rare tiers) and `rare_finds`.
2. When the user grants "use my location" on first-run, the client subscribes to `region_{outcode}` and stores the current outcode locally.
3. On outcode change (user moves), unsubscribe old, subscribe new.

## Backend changes

- New Cloud Function `onRareClaim` (Firestore trigger on `claims/{id}` create): if monarch is rare, send `admin.messaging().send({ topic: "rare_finds" | "monarch_{code}" | "region_{outcode}", notification: {...} })`.
- Rate-limit per-topic to max 3 messages per 24 h using Firestore counter doc `notificationRateLimits/{topic}`.
- Add topic to `_notifications.ts` helpers.

## Client changes

- `lib/services/fcm_topic_service.dart` wraps `FirebaseMessaging.instance.subscribeToTopic/unsubscribeFromTopic`.
- Settings screen gains "Rare find alerts" and "Claims in my area" toggles, mirrored in `users/{uid}/notificationPrefs`.

## Rollout

- Remote Config flag `feature_topic_alerts`.
- Begin with `rare_finds` only; add regional after a week of telemetry.

## Risks

- Topic flood during high-traffic claims: enforce rate limit + quiet hours (22:00–08:00 local).
- Topic name leakage is not sensitive (public monarch categories), but region outcode in the topic name is revealed in the client subscription call — acceptable since the user chose it.
