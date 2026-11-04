import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/wear/wear_claim_page.dart';

/// Pins the Wear-specific claim-error mapping. The native edge (Wear/Car)
/// re-implements / diverges from the phone copy, so these short watch strings
/// are guarded here the same way freshStreak and quiz_helpers are — to stop the
/// Wear path silently drifting from the server's error contract.
void main() {
  group('wearClaimErrorMessage', () {
    test('failed-precondition surfaces the travel-speed anti-spoof message', () {
      // startScoring throws `failed-precondition` for the travel-speed check;
      // the watch must tell the user to slow down, not show a generic failure.
      expect(wearClaimErrorMessage('failed-precondition'), 'Too fast. Slow down.');
    });

    test('unavailable maps to a connection message', () {
      expect(wearClaimErrorMessage('unavailable'), 'No connection.');
    });

    test('any other code falls back to a generic claim failure', () {
      for (final code in const ['internal', 'unauthenticated', 'not-found', '']) {
        expect(wearClaimErrorMessage(code), 'Claim failed',
            reason: 'unexpected mapping for "$code"');
      }
    });

    test('messages stay short enough for a watch face', () {
      // Watch screens are tiny; keep every rendered message well under ~24 chars.
      for (final code in const ['failed-precondition', 'unavailable', 'internal']) {
        expect(wearClaimErrorMessage(code).length, lessThanOrEqualTo(24),
            reason: '"$code" message is too long for the watch');
      }
    });
  });
}
