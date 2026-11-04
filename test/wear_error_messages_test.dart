import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/location_service.dart';
import 'package:postbox_game/wear/wear_error_messages.dart';

/// Pins the consolidated Wear location-error copy. Three Wear call sites
/// (compass scan, claim scan, claim attempt) previously duplicated this switch;
/// these tests guard the single source of truth so the watch copy can't drift
/// or grow too long for a round watch face.
void main() {
  group('wearLocationErrorMessage', () {
    test('servicesDisabled is action-independent', () {
      expect(
        wearLocationErrorMessage(LocationErrorKind.servicesDisabled, action: 'scan'),
        'Turn on location',
      );
      expect(
        wearLocationErrorMessage(LocationErrorKind.servicesDisabled, action: 'claim'),
        'Turn on location',
      );
    });

    test('permissionPermanentlyDenied is action-independent', () {
      expect(
        wearLocationErrorMessage(LocationErrorKind.permissionPermanentlyDenied,
            action: 'scan'),
        'Location denied. Enable in settings.',
      );
    });

    test('permissionDenied folds the action verb into the message', () {
      expect(
        wearLocationErrorMessage(LocationErrorKind.permissionDenied, action: 'scan'),
        'Location needed to scan',
      );
      expect(
        wearLocationErrorMessage(LocationErrorKind.permissionDenied, action: 'claim'),
        'Location needed to claim',
      );
    });

    test('every message is non-empty for all kinds', () {
      for (final kind in LocationErrorKind.values) {
        expect(wearLocationErrorMessage(kind, action: 'scan'), isNotEmpty);
      }
    });
  });
}
