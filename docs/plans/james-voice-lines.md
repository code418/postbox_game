# Plan — Postman James voice lines

- **Status:** Proposed
- **Effort:** Medium
- **Firebase services:** Cloud Storage, Remote Config (asset index)

## Overview

Give James an optional voiced layer. Short MP3/OGG lines are hosted in Cloud Storage, downloaded lazily, and cached on device. Keeps the APK small while allowing new lines to ship without an app release.

## Asset pipeline

- Each James line has an id (e.g. `idle_rain_01`).
- Audio recorded by a voice artist; normalise to -16 LUFS; export OGG Opus 24 kbps (~20 KB per line).
- Stored at `james-audio/{locale}/{lineId}.ogg`.
- An `index.json` at `james-audio/{locale}/index.json` lists `{ lineId: { path, durationMs, hash } }`.
- Remote Config param `james_audio_index_url_{locale}` points at the index (versioned).

## Client

- `lib/services/james_audio_service.dart`:
  - Fetch index on login, cache locally.
  - When `JamesController` shows a line with a known id, start async download-if-missing and `just_audio` playback.
  - LRU on-device cache (30 MB max).
- User toggle in settings: "James speaks aloud" (default OFF so we don't surprise users).
- Respect device silent mode.

## Text ↔ audio mapping

- Extend `lib/james_messages.dart` entries with an optional `audioId`.
- Fall back silently to text-only if the audio is missing or the device can't reach storage.

## Rollout

- Ship with a small starter set (10 lines) behind flag `feature_james_audio`.
- Add new lines via console upload + Remote Config bump, no client release needed.

## Risks

- Accessibility: never replace text with audio alone — always show the line.
- Data usage — pre-warm only after Wi-Fi detected; respect "data saver".
- Licensing: secure written release from the voice artist.

## Testing

- Unit test the LRU cache eviction.
- Integration test index fetch + single playback in a headless Flutter test using a fake `AudioPlayer`.
