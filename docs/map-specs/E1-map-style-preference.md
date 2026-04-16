# E1 — Map style preference

- **Status:** Proposed
- **Screen:** Settings (`lib/settings_screen.dart`)
- **Effort:** Small
- **Privacy:** Compatible

## Overview

Add a setting under "App" for choosing the map style: **Standard** (OSM),
**Satellite**, **Dark**, or **Terrain**. Stores the choice in
`SharedPreferences` via `AppPreferences`. `PostboxMap` reads the
preference at build time to select the tile URL.

## User flow

1. User opens Settings → App.
2. New list tile: **"Map style"** with current value as subtitle.
3. Tap opens a bottom sheet (same pattern as `_chooseDistanceUnit` in
   `settings_screen.dart:126`).
4. Options: Standard, Satellite, Dark, Terrain.
5. Selected value is applied everywhere maps appear in the app.

## Technical approach

- Extend `AppPreferences` with `getMapStyle()` / `setMapStyle()`.
- Define a `MapStyle` enum with `{ key, tileUrl, darkTileUrl, displayName }`.
- `PostboxMap` reads the preference on init and picks `tileUrl` accordingly.
- Dark-mode auto-switch: if `MapStyle.auto` and `Theme.of(context).brightness
  == Brightness.dark`, use the dark tile URL.
- Use `ValueNotifier<MapStyle>` or Stream so maps react to live changes
  without restart.

## Files affected

- `lib/app_preferences.dart` — new prefs.
- `lib/widgets/postbox_map.dart` — read and respect the preference.
- `lib/settings_screen.dart` — new setting tile + bottom sheet.

## Backend changes

None. Tile provider URL is client-side configuration. Production tile
provider (Stadia Maps etc.) is still defined globally; this preference
only chooses between styles within that provider.

## Privacy considerations

- Tile URLs go to the map provider. That provider will see the user's
  approximate viewport. Document this in the privacy policy.
- No new PII leak beyond what a map already exposes.

## Open questions

- Which tile providers offer free or low-cost satellite tiles? (Mapbox
  and MapTiler do; OSM does not ship satellite.)
- Should we bundle a local "low-fi" style for offline use?
- Terrain style seems overkill — drop it?
