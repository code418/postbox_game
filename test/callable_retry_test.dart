// Unit tests for retryOnUnavailable (ROADMAP v1.5, offline play Phase 1).
//
// The retry seam lives in lib/firebase_functions_eu.dart beside the region
// pin: transient transport failures (`unavailable`, `deadline-exceeded`) are
// retried with jittered backoff, everything else surfaces immediately. Only
// idempotent calls may use it — startScoring is safe solely because it now
// carries an attemptId the server replays (see functions/src/_attempts.ts).

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/firebase_functions_eu.dart';

FirebaseFunctionsException _ex(String code) =>
    // ignore: invalid_use_of_protected_member
    FirebaseFunctionsException(message: 'test', code: code);

void main() {
  test('returns the first successful result without delays', () async {
    var calls = 0;
    final delays = <Duration>[];
    final result = await retryOnUnavailable(
      () async {
        calls++;
        return 'ok';
      },
      delay: (d) async => delays.add(d),
    );
    expect(result, 'ok');
    expect(calls, 1);
    expect(delays, isEmpty);
  });

  test('retries unavailable with growing backoff, then succeeds', () async {
    var calls = 0;
    final delays = <Duration>[];
    final result = await retryOnUnavailable(
      () async {
        calls++;
        if (calls < 3) throw _ex('unavailable');
        return 'ok';
      },
      delay: (d) async => delays.add(d),
    );
    expect(result, 'ok');
    expect(calls, 3);
    expect(delays, hasLength(2));
    expect(delays[1], greaterThan(delays[0]));
  });

  test('retries deadline-exceeded', () async {
    var calls = 0;
    final result = await retryOnUnavailable(
      () async {
        calls++;
        if (calls == 1) throw _ex('deadline-exceeded');
        return 42;
      },
      delay: (_) async {},
    );
    expect(result, 42);
    expect(calls, 2);
  });

  test('does not retry non-transport codes', () async {
    var calls = 0;
    await expectLater(
      retryOnUnavailable(
        () async {
          calls++;
          throw _ex('failed-precondition');
        },
        delay: (_) async {},
      ),
      throwsA(isA<FirebaseFunctionsException>()
          .having((e) => e.code, 'code', 'failed-precondition')),
    );
    expect(calls, 1);
  });

  test('does not retry arbitrary exceptions', () async {
    var calls = 0;
    await expectLater(
      retryOnUnavailable(
        () async {
          calls++;
          throw StateError('boom');
        },
        delay: (_) async {},
      ),
      throwsA(isA<StateError>()),
    );
    expect(calls, 1);
  });

  test('gives up after maxRetries and rethrows the last error', () async {
    var calls = 0;
    await expectLater(
      retryOnUnavailable(
        () async {
          calls++;
          throw _ex('unavailable');
        },
        maxRetries: 2,
        delay: (_) async {},
      ),
      throwsA(isA<FirebaseFunctionsException>()
          .having((e) => e.code, 'code', 'unavailable')),
    );
    expect(calls, 3); // initial + 2 retries
  });

  group('App Check / sign-in verification failures', () {
    // Callables declared `enforceAppCheck: true` (nearbyPostboxes,
    // startScoring, flushOfflineClaims) are rejected by the PLATFORM before
    // the handler runs, so the server's own requireAppCheck copy never
    // reaches the client — it arrives as a bare `unauthenticated`. Every
    // screen used to answer that with "Please try again", which cannot fix
    // either a failed attestation or a stale sign-in.
    test('the verification code is never retried', () {
      expect(retryableCallableCodes, isNot(contains(appVerificationFailedCode)),
          reason: 'retrying cannot mint a valid App Check token');
    });

    test('surfaces immediately rather than burning retries', () async {
      var calls = 0;
      await expectLater(
        retryOnUnavailable(
          () async {
            calls++;
            throw _ex(appVerificationFailedCode);
          },
          delay: (_) async {},
        ),
        throwsA(isA<FirebaseFunctionsException>()),
      );
      expect(calls, 1);
    });

    test('the message tells the user something they can act on', () {
      expect(appVerificationMessage.toLowerCase(), isNot(contains('try again.')),
          reason: 'retrying is exactly what does not work here');
      expect(appVerificationMessage.toLowerCase(), contains('sign'));
      expect(appVerificationMessage.toLowerCase(), contains('reinstall'));
    });
  });
}
