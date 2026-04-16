# K1 — Map / list toggle

- **Status:** Proposed (cross-cutting)
- **Screen:** Every screen that gains a map view
- **Effort:** Small per screen
- **Privacy:** Compatible

## Overview

For every screen that gains a map view, also keep the existing
list / card view. Provide a toggle (typically a `SegmentedButton` in the
AppBar or a chip at the top of the content) so users can switch between
the two representations. Preserves accessibility and caters to users
who prefer lists.

## User flow

1. On a screen with both views, a `SegmentedButton` shows **Map** /
   **List** (or **Compass** / **Map** on the Nearby screen).
2. Selected segment is highlighted in postal red.
3. User's choice persists per screen via `SharedPreferences` so their
   preferred view sticks across app launches.

## Technical approach

- Reusable `ViewToggle` widget wrapping `SegmentedButton<ViewMode>`.
- Per-screen preference key: `view.mode.${screenName}`.
- Reads / writes via `AppPreferences`.

## Files affected

- `lib/widgets/view_toggle.dart` — new reusable widget.
- `lib/app_preferences.dart` — new per-screen view preferences.
- Each map-enabled screen — include the toggle in its AppBar or header.

## Backend changes

None.

## Privacy considerations

- Screen-reader-first users can always stay on the list view, avoiding
  the inherent visual nature of maps.
- No new data exposure.

## Open questions

- One global preference ("prefer maps everywhere") or per-screen? Start
  per-screen; add a global setting later if users request it.
- Should the toggle be in the AppBar (permanent) or in a floating
  action area (less prominent)? AppBar is clearer but more crowded.
