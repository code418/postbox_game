# E2 — Home location marker

- **Status:** Proposed
- **Screen:** Settings (`lib/settings_screen.dart`)
- **Effort:** Small
- **Privacy:** Compatible (local-only)

## Overview

Allow the user to set a "home" location by long-pressing on a map. The
location is stored **locally only** (never sent to the server). Used as
the default centre when no GPS fix is available and as a reference
landmark on any map preview.

## User flow

1. User opens Settings → App.
2. Taps **"Home location"**.
3. A full-screen map opens, centred on the user's current position.
4. User long-presses (or drags a pin) to set their home.
5. Tap **Save** to store the location.
6. Later, in nearby / claim scans that fail to get a GPS fix, the map
   falls back to the home centre.
7. User can clear the home location any time via the same screen.

## Technical approach

- Store as `{ lat, lng }` in `SharedPreferences` under
  `AppPreferences.homeLocation`.
- Use `PostboxMap` with a single draggable marker (`Marker` with
  `child: Icon(Icons.home)` + `GestureDetector` for drag events).
- Provide a "Use current location" button that reads `getPosition()`.

## Files affected

- `lib/app_preferences.dart` — new `getHomeLocation` / `setHomeLocation`.
- `lib/home_location_screen.dart` — new screen.
- `lib/settings_screen.dart` — new setting tile.

## Backend changes

None. Home location is stored locally only. **Do not** send this to
Firestore even for convenience — it is personal information.

## Privacy considerations

- Purely client-side storage.
- Not uploaded to any server.
- Cleared when the app is uninstalled or via the "Clear" button.
- If the user signs out, consider clearing the home location too (minor
  privacy hygiene).

## Open questions

- Should we provide a "home" quick-action on the Nearby screen?
- Should the home location affect the default zoom of maps in the app?
- Consider adding "work" location as a second saved place.
