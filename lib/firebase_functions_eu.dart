import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';

/// Region-pinned [FirebaseFunctions] for the app's Cloud Functions.
///
/// All callables are deployed to `europe-west2` (see `functions/src/_region.ts`
/// and ROADMAP v1.3). The default [FirebaseFunctions.instance] targets
/// `us-central1`, so every call site must go through this getter to stay
/// in-region — using the US default would add a cross-Atlantic round-trip.
///
/// [FirebaseFunctions.instanceFor] caches per (app, region), so reading this
/// getter repeatedly is cheap.
FirebaseFunctions get appFunctions =>
    FirebaseFunctions.instanceFor(region: 'europe-west2');

/// Callable error codes that mean the request may never have reached (or
/// returned from) the server — the transport failed, not the function.
const Set<String> retryableCallableCodes = {'unavailable', 'deadline-exceeded'};

/// The code the Functions platform returns when a callable declared with
/// `enforceAppCheck: true` rejects a request whose App Check token is missing
/// or malformed — `nearbyPostboxes`, `startScoring`, `flushOfflineClaims`.
///
/// The server's own `requireAppCheck` has good copy for this ("App attestation
/// failed. Please update the app..."), but it never runs: the platform layer
/// rejects first, and its code is indistinguishable from a genuinely expired
/// auth token. Both are covered by [appVerificationMessage], because retrying
/// — which is what every one of these screens used to advise — cannot fix
/// either.
const String appVerificationFailedCode = 'unauthenticated';

/// Actionable copy for [appVerificationFailedCode]. Covers both causes: a
/// stale sign-in (fixed by signing in again) and a failed Play Integrity
/// attestation (fixed by installing a genuine build from Play).
const String appVerificationMessage =
    "Couldn't verify your app. Try signing in again, or reinstall from Google "
    'Play if this keeps happening.';

Duration _defaultBackoff(int attempt) => Duration(
    milliseconds: 300 * (1 << attempt) + Random().nextInt(200));

/// Retries [call] on transient transport failures (`unavailable` /
/// `deadline-exceeded`) with jittered exponential backoff; every other error
/// surfaces immediately (ROADMAP v1.5, offline play Phase 1).
///
/// ONLY wrap idempotent calls. A dropped RESPONSE leaves the server state
/// changed, so retrying a non-idempotent write risks double-processing —
/// `startScoring` is safe solely because it carries an `attemptId` whose
/// stored response the server replays (functions/src/_attempts.ts); scans
/// (`nearbyPostboxes`) are read-only and safe wholesale.
///
/// [delay] and [backoff] are injectable for tests.
Future<T> retryOnUnavailable<T>(
  Future<T> Function() call, {
  int maxRetries = 2,
  Duration Function(int attempt) backoff = _defaultBackoff,
  Future<void> Function(Duration)? delay,
}) async {
  final wait = delay ?? (Duration d) => Future<void>.delayed(d);
  for (var attempt = 0;; attempt++) {
    try {
      return await call();
    } on FirebaseFunctionsException catch (e) {
      if (attempt >= maxRetries || !retryableCallableCodes.contains(e.code)) {
        rethrow;
      }
      await wait(backoff(attempt));
    }
  }
}
