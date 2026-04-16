# K2 — Offline tile caching

- **Status:** Proposed (cross-cutting)
- **Screen:** All map views
- **Effort:** Medium
- **Privacy:** Compatible

## Overview

Cache map tiles on-device so maps work in poor-signal areas (common for
postbox hunting in rural spots or urban pockets). Uses
`flutter_map_tile_caching` or built-in HTTP caching. Surfaces an
"Offline maps" setting so users can pre-download a region.

## User flow

1. Casual use: tiles the user has already loaded are served from cache
   on revisit, even offline.
2. Power use: **Settings → Offline maps** opens a screen where the user
   can select a region on a map and tap **Download**.
3. A progress bar shows MB and estimated tile count.
4. Downloaded regions are listed with size and last-refreshed date.
5. Each region has Delete and Refresh actions.

## Technical approach

- Add `flutter_map_tile_caching` (FMTC) package.
- Configure a default store that caches tiles for N days (e.g. 30).
- For opt-in regions, create a named store per region and pre-download
  via FMTC's bulk download API.
- Respect the user's data-saver / battery state.

## Files affected

- `pubspec.yaml` — add `flutter_map_tile_caching`.
- `lib/widgets/postbox_map.dart` — use FMTC-backed `TileProvider`.
- `lib/offline_maps_screen.dart` — new screen.
- `lib/settings_screen.dart` — new tile linking to it.

## Backend changes

None (tile provider usage policies must be respected; see Open
questions).

## Privacy considerations

- Cached tiles are device-local; no new server interaction.
- Pre-download respects user-triggered consent.

## Open questions

- OSM's usage policy limits bulk download. Must switch to a paid
  provider (Stadia Maps, Mapbox, MapTiler) before shipping bulk
  pre-download. Casual caching is fine.
- Cache size limits: cap at 500 MB by default?
- Should Postman James announce when tiles fail to load offline? "Bit
  foggy out there — your map's in black and white."
