# Plan — App Check enforcement audit and hardening

- **Status:** Proposed
- **Effort:** Small
- **Firebase services:** App Check (Play Integrity, DeviceCheck / App Attest), Cloud Functions, Firestore, Storage, RTDB

## Overview

App Check is already configured client-side for Android release. This plan audits and enforces App Check on every Firebase service the app uses so that API keys leaked from a release binary cannot be used to call the backend from an unmodified environment.

## Checklist

1. **Android debug provider** — add `AndroidDebugProvider` with a debug token committed to developer machines only, not the repo.
2. **iOS** — activate `AppleProvider` (`DeviceCheck` / `AppAttest`) once iOS builds are wired up. Block until then.
3. **Firebase Console enforcement:**
   - Cloud Functions (callable + HTTPS) → enforce.
   - Firestore → enforce.
   - Cloud Storage → enforce.
   - Realtime Database (if/when presence plan ships) → enforce.
4. **Cloud Functions code:** for each callable, `context.app` must be set; reject with `failed-precondition` if absent (on top of platform enforcement, for defence-in-depth).
5. **Monitoring:** add a Cloud Monitoring alert on App Check denial rate spikes.

## Files affected

- `lib/main.dart` — expand provider selection per platform.
- `functions/src/index.ts` — guard helper for `context.app` presence.
- New `functions/src/_appCheck.ts` — wrap callables.

## Rollout

- Enable in **monitor mode** first for 7 days to measure legitimate-traffic denial rate.
- Switch to **enforce** if denial rate < 1 %.
- Keep a break-glass env var to temporarily disable the explicit `context.app` check in case of provider outage.

## Risks

- Older device OS versions where Play Integrity is flaky → collect denial telemetry and whitelist a device fallback if needed.
- Internal CI/integration tests calling Functions — use App Check debug tokens, never disable enforcement.

## Testing

- Integration test that calls a Function without App Check header → expect denial when enforce is on.
