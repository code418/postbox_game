# Movement-triggered rescan on the Claim empty state

**Date:** 2026-06-17
**Status:** design approved, pending implementation plan
**Area:** `lib/widgets/claim_quiz_sheet.dart` (Claim tab scan-and-quiz flow)

## Problem

When a scan finds no postboxes within the claim radius, the Claim screen shows
the empty state (`_buildEmpty`). Today that state offers two actions:

- **Report a missing postbox** (gated behind the reporting kill-switch)
- **Back** (returns to the initial Scan screen)

It has **no rescan affordance**. A user who finds nothing, walks a short
distance, and wants to try again has to tap **Back** and then **Scan** again.
The `results` and `quizFailed` states already carry a "Rescan location" button;
`empty` is the only scan-outcome state without one.

## Goal

While the user is sitting on the "No postboxes found" screen, detect when they
have physically moved a few metres from where they scanned and surface a
**Rescan** option that re-scans immediately at their current position.

Confirmed product decisions:

- **Move threshold:** 10 m from the scan point before the Rescan option appears.
  Far enough that a rescan can plausibly bring new postboxes into the 30 m claim
  radius, while ignoring GPS jitter.
- **Rescan behaviour:** in-place re-scan (Option B), not a bounce back to the
  Scan button. Tapping Rescan re-runs the search at the user's current position
  and stays in the sheet.
- **Trigger:** manual button that *appears* once movement is detected — not an
  automatic rescan.

## Approach (Option B — in-place rescan)

The existing "Rescan location" buttons (`results`, `quizFailed`) call `_cancel()`,
which hands control back to the Claim screen and resets it to the initial Scan
button (two taps to actually rescan). For the empty state we instead re-run
`_runSearch()` directly at the user's current position and stay in the sheet,
landing straight on `searching → results`/`empty`. This reuses the GPS fix we
already obtain from the movement-detection stream, so there is no extra location
call.

This also fixes a latent inconsistency: the post-claim retry paths
(`claim_quiz_sheet.dart:444` and `:454`) already re-run the search at a fresh
position via `_runSearch(position: freshPos)`, but `_claimRadiusMap` stays
pinned to the immutable `widget.scanPosition`, so the map can show a stale
centre. Threading the search centre through state fixes both call sites.

## Components / changes

All changes are in `lib/widgets/claim_quiz_sheet.dart`.

1. **Scan-centre as state.** Add `LatLng _scanCenter`, initialised to
   `widget.scanPosition` in `initState`. Update it at the top of `_runSearch`
   (to the passed `position`, falling back to `widget.scanPosition`).
   `_claimRadiusMap` reads `_scanCenter` instead of `widget.scanPosition`.

2. **Movement watch (empty state only).** When `_runSearch` lands on
   `_QuizStage.empty`, subscribe to a position stream. On each fix, compute
   `Geolocator.distanceBetween(_scanCenter, fix)`; once it is ≥ 10 m, set
   `_movedSinceScan = true` and store the latest fix (`_latestFix`). Cancel the
   subscription whenever we leave `empty` (top of `_runSearch`) and in
   `dispose`. Reset `_movedSinceScan` / `_latestFix` on each new search. Stream
   errors are swallowed: permission is already held (the scan succeeded), so an
   error simply means the button never appears. The watch is gated to
   `!widget.compact` — route/compact mode already tracks movement itself, and
   the empty sheet there is transient.

3. **Rescan button in `_buildEmpty`.** Shown only when `_movedSinceScan` is
   true. A primary `FilledButton.icon` ("Rescan from here", `Icons.refresh`),
   placed above the existing "Report a missing postbox" / "Back" actions.
   `onPressed` → `_runSearch(position: _latestFix ?? _scanCenter)`.

4. **Test seam.** Add an injectable
   `Stream<Position> Function()? positionStreamProvider` widget parameter,
   defaulting to `positionStream` from `location_service.dart`, mirroring the
   existing `positionProvider` / `nearbyCallable` / `startScoringCallable`
   seams. The movement watch calls this provider so a widget test can pump a
   fake "user moved" position.

### Threshold constant

Introduce a private constant for the 10 m threshold (e.g.
`_emptyRescanMoveThresholdM = 10.0`) rather than a bare literal, so the value is
named and discoverable.

## Data flow

```
_runSearch (count == 0)
  → _QuizStage.empty
  → subscribe to positionStreamProvider()           (only when !compact)
  → each fix: distanceBetween(_scanCenter, fix) ≥ 10 m ?
       → _movedSinceScan = true, _latestFix = fix
  → "Rescan from here" button appears in _buildEmpty
  → tap → cancel watch → _runSearch(position: _latestFix)
       → _QuizStage.searching → results / empty
         (map now centred on _scanCenter == the new spot)
```

## Error handling

- Position-stream errors: caught in the subscription's `onError`; cancel the
  subscription and leave the button hidden. No SnackBar — this is a passive
  enhancement, not a user-initiated action.
- Rescan tap reuses the existing `_runSearch` error handling (offline, timeout,
  location-permission, generic) unchanged.

## Testing

Add a widget test (alongside the existing Claim/quiz tests):

1. Inject `nearbyCallable` returning a zero-count result and a controllable
   `positionStreamProvider`.
2. Render `ClaimQuizSheet`; let the initial search settle on the empty state;
   assert **no** "Rescan from here" button.
3. Emit a fake position ~12 m from the scan position through the injected
   stream; pump; assert "Rescan from here" **appears**.
4. Tap it; assert a re-scan fires (the injected `nearbyCallable` is invoked
   again with the new coordinates).

Existing 105 Dart tests must stay green.

## Out of scope

- No new Postman James line (the existing `claimScanEmpty` line still fires on
  entry to the empty state).
- No automatic rescan — the button only *appears*; the user taps it.
- Route/compact mode behaviour is unchanged (movement watch is gated off there).
- The `results` / `quizFailed` "Rescan location" buttons keep their current
  bounce-back behaviour (not in scope to change).
