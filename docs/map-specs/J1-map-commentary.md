# J1 — Postman James map commentary

- **Status:** Proposed
- **Screen:** Any map-enabled screen
- **Effort:** Small
- **Privacy:** Compatible

## Overview

When any map is visible, trigger contextual `JamesMessages` based on
what the map is showing: dense cluster, sparse area, user's coverage,
etc. Reinforces Postman James as a persistent guide and keeps the
British-humour tone present on map screens.

## User flow

1. User lands on a map-enabled screen (e.g. Nearby with A2).
2. After a brief delay (1–2 seconds), James says something relevant:
   - Cluster visible on the heatmap: "Blimey, that's quite a cluster.
     Pick a direction and off you pop."
   - Empty sector: "Nothing that way. Try somewhere else — even a
     postman can't magic one up."
   - User's coverage map: "A respectable patch, if I do say so."
   - Streak map: "Seven in a row. I'd tip my cap if I had one."
3. Messages use the existing James strip (`lib/james_strip.dart`).
4. Idle non-sequiturs (every 2–5 minutes) continue as normal.

## Technical approach

- Add new entries to `lib/james_messages.dart` under a `map` category:
  `mapCluster`, `mapEmpty`, `mapCoverageSmall`, `mapCoverageLarge`,
  `mapStreakLong`, etc.
- In each map-enabled screen, after the map has data, call
  `JamesController.of(context)?.show(JamesMessages.mapCluster.resolve())`.
- Throttle to at most one message per screen per session.

## Files affected

- `lib/james_messages.dart` — add entries.
- Each map screen — call the appropriate message once.

## Backend changes

None.

## Privacy considerations

- None; James messages are cosmetic.

## Open questions

- Should James ever comment on a specific cipher ("ooh, a rare one")?
  Only safe after a claim (B2) so this doesn't reveal locations.
- How chatty is too chatty? Cap at one message per map interaction.
