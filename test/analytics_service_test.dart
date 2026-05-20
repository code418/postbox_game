import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/analytics_user_properties.dart';

/// Hand-rolled fake mirroring the surface that `Analytics.setUserId` and
/// `Analytics.setUserProperty` touch. `Fake` causes any non-overridden member
/// to throw — catches drift if the wrapper starts reaching for unrelated
/// plugin APIs (matches the `_FakeRemoteConfig` pattern in
/// `remote_config_service_test.dart`).
class _FakeFirebaseAnalytics extends Fake implements FirebaseAnalytics {
  String? lastUserId;
  bool setUserIdCalled = false;
  final Map<String, String?> properties = <String, String?>{};

  @override
  Future<void> setUserId({
    String? id,
    AnalyticsCallOptions? callOptions,
  }) async {
    setUserIdCalled = true;
    lastUserId = id;
  }

  @override
  Future<void> setUserProperty({
    required String name,
    required String? value,
    AnalyticsCallOptions? callOptions,
  }) async {
    properties[name] = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeFirebaseAnalytics fake;

  setUp(() {
    fake = _FakeFirebaseAnalytics();
    Analytics.instance = fake;
    Analytics.resetUserPropertiesForTest();
  });

  group('Analytics.setUserId', () {
    test('forwards the uid to FirebaseAnalytics', () async {
      await Analytics.setUserId('uid-abc');
      expect(fake.setUserIdCalled, isTrue);
      expect(fake.lastUserId, equals('uid-abc'));
    });

    test('null clears the recorded id', () async {
      await Analytics.setUserId('uid-abc');
      await Analytics.setUserId(null);
      expect(fake.setUserIdCalled, isTrue);
      expect(fake.lastUserId, isNull);
    });
  });

  group('Analytics.setUserProperty', () {
    test('forwards single key/value to FirebaseAnalytics', () async {
      await Analytics.setUserProperty(AnalyticsUserProps.kIsAdmin, 'true');
      expect(fake.properties[AnalyticsUserProps.kIsAdmin], equals('true'));
    });

    test('mirrors the value into lastSetUserProperties', () async {
      await Analytics.setUserProperty(
          AnalyticsUserProps.kFriendCountBucket, '4-10');
      expect(
        Analytics.lastSetUserProperties[AnalyticsUserProps.kFriendCountBucket],
        equals('4-10'),
      );
    });

    test('null value records as null (so audiences can match "unset")',
        () async {
      await Analytics.setUserProperty(AnalyticsUserProps.kMapColor, null);
      expect(fake.properties[AnalyticsUserProps.kMapColor], isNull);
      expect(Analytics.lastSetUserProperties[AnalyticsUserProps.kMapColor],
          isNull);
    });
  });

  group('Analytics.setUserProperties', () {
    test('writes every property in the snapshot', () async {
      final snap = snapshotFromUserDoc(
        <String, dynamic>{
          'streak': 9,
          'lifetimePoints': 1500,
          'uniquePostboxesClaimed': 60,
          'friends': <String>['a', 'b'],
          'lastClaimDate': '2026-05-20',
          'mapColor': 'postalRed',
        },
        isAdmin: true,
        hasSeenIntro: true,
        todayLondonIso: '2026-05-20',
      );
      await Analytics.setUserProperties(snap);

      expect(fake.properties[AnalyticsUserProps.kIsAdmin], 'true');
      expect(fake.properties[AnalyticsUserProps.kHasSeenIntro], 'true');
      expect(fake.properties[AnalyticsUserProps.kClaimStreakBucket], '8-30');
      expect(fake.properties[AnalyticsUserProps.kLifetimePointsBucket],
          '1001-10000');
      expect(fake.properties[AnalyticsUserProps.kUniquePostboxesBucket],
          '51-200');
      expect(fake.properties[AnalyticsUserProps.kFriendCountBucket], '1-3');
      expect(fake.properties[AnalyticsUserProps.kClaimedToday], 'true');
      expect(fake.properties[AnalyticsUserProps.kMapColor], 'postalRed');
    });

    test('lastSetUserProperties exposes every key after a snapshot push',
        () async {
      final snap = snapshotFromUserDoc(
        <String, dynamic>{},
        isAdmin: false,
        hasSeenIntro: false,
        todayLondonIso: '2026-05-20',
      );
      await Analytics.setUserProperties(snap);

      expect(Analytics.lastSetUserProperties.keys.toSet(),
          equals(AnalyticsUserProps.all.toSet()));
    });
  });

  group('Analytics.lastSetUserProperties', () {
    test('returns an unmodifiable map', () async {
      await Analytics.setUserProperty(AnalyticsUserProps.kIsAdmin, 'false');
      expect(
        () => Analytics.lastSetUserProperties['anything'] = 'x',
        throwsA(isA<UnsupportedError>()),
      );
    });
  });
}
