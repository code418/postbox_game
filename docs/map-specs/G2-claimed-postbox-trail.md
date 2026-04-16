# G2 — Claimed postbox trail

- **Status:** Proposed
- **Screen:** New full-screen map (reachable from Profile or Settings)
- **Effort:** Medium
- **Privacy:** Compatible (user's own history only) — requires backend change

## Overview

Show the user's claim history as a trail on a map — each claimed postbox
appears as a pin (cipher-coloured) connected chronologically by a thin
polyline. Tells the story of the player's hunting journey.

## User flow

1. User opens **Profile** or **Settings → My claim history**.
2. A full-screen map opens.
3. All the user's lifetime claims appear as pins coloured by cipher.
4. A thin grey polyline connects them in chronological order.
5. Tapping a pin shows a card with the date, cipher, and points earned.
6. Date-range filters: Last week / Last month / All time.
7. A toggle lets the user switch between "trail" and "cluster" view
   (the latter shows heatmap density for users with thousands of claims).

## Technical approach

- Extend the `claims` Firestore document to include `{ lat, lng, cipher,
  claimedAt }` at claim time.
- New Cloud Function `getUserClaimHistory(limit, startAfter)` with
  pagination.
- Client renders `Marker`s via `postboxMarker(point, cipher: cipher)`
  and a single `Polyline` connecting them.
- For large histories, implement viewport-based loading and marker
  clustering (flutter_map_marker_cluster package).

## Files affected

- `functions/src/startScoring.ts` — write lat/lng into the claim doc.
- `functions/src/index.ts` — new `getUserClaimHistory` callable.
- `firestore.rules` — allow users to read their own claims.
- `lib/claim_history_screen.dart` — new screen.
- `lib/settings_screen.dart` — add a new tile linking to it.
- Migration script for historical claims that lack lat/lng (best-effort
  join to current postbox positions).

## Backend changes

- Claims gain `lat`, `lng`, `cipher` fields.
- Backfill script for historical claims.

## Privacy considerations

- A user's own claim history is by definition data they have access to.
- The history is **not** shared unless opted in via friends/sharing flows.
- **Does not violate game rules** — the locations shown are of postboxes
  the user has already claimed, not unclaimed ones.

## Open questions

- How to handle GPS-drift ambiguity: store the user's claim position
  (GPS at time of claim) or the postbox's canonical position? Former is
  more "where I was", latter is more "where the box is". Recommend the
  postbox's canonical position.
- Should deleted claims (if such a thing exists) disappear from the
  trail?
- Privacy: what if a user wants to redact a location from their history?
