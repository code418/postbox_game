# Plan — Abuse detection (impossible-travel and claim anomalies)

- **Status:** Proposed
- **Effort:** Medium
- **Firebase services:** Cloud Functions (Firestore trigger), Firestore, App Check

## Overview

Detect location-spoofing and claim-farming by flagging physically implausible sequences. Write suspicious events to a moderation queue; do not auto-block in phase 1.

## Signals

- **Impossible travel:** two claims < N minutes apart separated by distance requiring > 200 km/h.
- **Repeated device ID on different accounts:** store install ID hash on claim; flag when same hash claims across ≥ 3 accounts in 24 h.
- **Clustered claims in identical coordinates:** same lat/lng to 6 dp repeated across sessions.
- **Out-of-window claims:** location server-timestamp delta vs. client timestamp > 2 min (already partially checked in `startScoring`).

## Data model

- `claims/{id}` gains `deviceIdHash`, `clientTsMs`.
- `moderation/flags/{flagId}` = `{ uid, reason, severity, claimId?, createdAt, reviewed, action? }`.
- `users/{uid}.trustScore` (server-only) decays with flags, recovers over time.

## Implementation

- Firestore trigger `onClaimCreated` (or inline in `startScoring`) computes the signals against the user's previous claim.
- Uses `geolib.getDistance` or haversine; compare with `(now - prevTs)` to get km/h.
- Writes a flag doc on threshold breach. Emits a Crashlytics non-fatal for internal visibility.
- Phase 2: when `trustScore < threshold`, require step-up verification (reCAPTCHA challenge via App Check) before claim counts.

## Admin surface

- Simple Cloud Function `listFlags(page)` protected by custom claim `role: "moderator"`.
- Optional tiny Hosting admin page (plan in its own PR if shipped).

## Rollout

- Shadow mode first: log flags, no user-facing effect.
- After 2 weeks of data, tune thresholds using Firestore exports.

## Risks

- False positives from legitimate long train journeys with a gap — mitigate by requiring signal + supporting signal (e.g. impossible travel AND repeated device hash).
- Device ID stability across reinstalls — use `firebase_installations` ID, accept some churn.

## Testing

- Unit test the distance/speed calc with fixture claim pairs.
- Integration test: inject a spoofed sequence, assert flag is written.
