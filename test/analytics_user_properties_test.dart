import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/analytics_user_properties.dart';

void main() {
  group('streakBucket', () {
    test('boundaries map to the expected bucket strings', () {
      expect(streakBucket(-1), '0');
      expect(streakBucket(0), '0');
      expect(streakBucket(1), '1-3');
      expect(streakBucket(3), '1-3');
      expect(streakBucket(4), '4-7');
      expect(streakBucket(7), '4-7');
      expect(streakBucket(8), '8-30');
      expect(streakBucket(30), '8-30');
      expect(streakBucket(31), '30+');
      expect(streakBucket(1000), '30+');
    });
  });

  group('lifetimePointsBucket', () {
    test('boundaries map to the expected bucket strings', () {
      expect(lifetimePointsBucket(0), '0');
      expect(lifetimePointsBucket(1), '1-100');
      expect(lifetimePointsBucket(100), '1-100');
      expect(lifetimePointsBucket(101), '101-1000');
      expect(lifetimePointsBucket(1000), '101-1000');
      expect(lifetimePointsBucket(1001), '1001-10000');
      expect(lifetimePointsBucket(10000), '1001-10000');
      expect(lifetimePointsBucket(10001), '10000+');
    });
  });

  group('uniquePostboxesBucket', () {
    test('boundaries map to the expected bucket strings', () {
      expect(uniquePostboxesBucket(0), '0');
      expect(uniquePostboxesBucket(1), '1-10');
      expect(uniquePostboxesBucket(10), '1-10');
      expect(uniquePostboxesBucket(11), '11-50');
      expect(uniquePostboxesBucket(50), '11-50');
      expect(uniquePostboxesBucket(51), '51-200');
      expect(uniquePostboxesBucket(200), '51-200');
      expect(uniquePostboxesBucket(201), '200+');
    });
  });

  group('friendCountBucket', () {
    test('boundaries map to the expected bucket strings', () {
      expect(friendCountBucket(0), '0');
      expect(friendCountBucket(1), '1-3');
      expect(friendCountBucket(3), '1-3');
      expect(friendCountBucket(4), '4-10');
      expect(friendCountBucket(10), '4-10');
      expect(friendCountBucket(11), '11+');
    });
  });

  group('mapColorProp', () {
    test('missing / empty maps to "default"', () {
      expect(mapColorProp(null), 'default');
      expect(mapColorProp(''), 'default');
      expect(mapColorProp('   '), 'default');
      expect(mapColorProp(42), 'default');
    });
    test('non-empty string passes through unchanged', () {
      expect(mapColorProp('postalRed'), 'postalRed');
      expect(mapColorProp('royal-navy'), 'royal-navy');
    });
  });

  group('boolProp', () {
    test('canonical "true"/"false" strings', () {
      expect(boolProp(true), 'true');
      expect(boolProp(false), 'false');
    });
  });

  group('snapshotFromUserDoc', () {
    test('complete doc — all buckets resolved', () {
      final snap = snapshotFromUserDoc(
        <String, dynamic>{
          'streak': 12,
          'lifetimePoints': 500,
          'uniquePostboxesClaimed': 42,
          'friends': <String>['a', 'b', 'c', 'd', 'e'],
          'lastClaimDate': '2026-05-20',
          'mapColor': 'postalRed',
        },
        isAdmin: true,
        hasSeenIntro: true,
        todayLondonIso: '2026-05-20',
      );
      expect(snap.isAdmin, 'true');
      expect(snap.hasSeenIntro, 'true');
      expect(snap.claimStreakBucket, '8-30');
      expect(snap.lifetimePointsBucket, '101-1000');
      expect(snap.uniquePostboxesBucket, '11-50');
      expect(snap.friendCountBucket, '4-10');
      expect(snap.claimedToday, 'true');
      expect(snap.mapColor, 'postalRed');
    });

    test('minimal doc (brand-new account) — buckets default to "0"/"false"',
        () {
      final snap = snapshotFromUserDoc(
        <String, dynamic>{},
        isAdmin: false,
        hasSeenIntro: false,
        todayLondonIso: '2026-05-20',
      );
      expect(snap.isAdmin, 'false');
      expect(snap.hasSeenIntro, 'false');
      expect(snap.claimStreakBucket, '0');
      expect(snap.lifetimePointsBucket, '0');
      expect(snap.uniquePostboxesBucket, '0');
      expect(snap.friendCountBucket, '0');
      expect(snap.claimedToday, 'false');
      expect(snap.mapColor, 'default');
    });

    test('lastClaimDate from a previous day → claimed_today=false', () {
      final snap = snapshotFromUserDoc(
        <String, dynamic>{'lastClaimDate': '2026-05-19'},
        isAdmin: false,
        hasSeenIntro: true,
        todayLondonIso: '2026-05-20',
      );
      expect(snap.claimedToday, 'false');
    });

    test('numeric fields stored as num (Firestore quirk) coerce to int', () {
      final snap = snapshotFromUserDoc(
        <String, dynamic>{
          'streak': 5.0,
          'lifetimePoints': 250.0,
          'uniquePostboxesClaimed': 15.0,
          // freshStreak treats a streak as broken (→ 0) when lastClaimDate is
          // missing, so provide today to keep the streak "live" and pin the
          // num-cast behaviour rather than the staleness guard.
          'lastClaimDate': '2026-05-20',
        },
        isAdmin: false,
        hasSeenIntro: true,
        todayLondonIso: '2026-05-20',
      );
      expect(snap.claimStreakBucket, '4-7');
      expect(snap.lifetimePointsBucket, '101-1000');
      expect(snap.uniquePostboxesBucket, '11-50');
    });

    test('stale streak (lastClaimDate older than yesterday) reads as "0"', () {
      // The server only resets `streak` on the user's next claim, so a user
      // who missed yesterday still has a non-zero stored value. The Remote
      // Config audience should reflect the live state, not the stale field
      // — same guard StreakService and HomeWidgetService apply via freshStreak.
      final snap = snapshotFromUserDoc(
        <String, dynamic>{
          'streak': 30,
          'lastClaimDate': '2026-05-17', // 3 days before today below
        },
        isAdmin: false,
        hasSeenIntro: true,
        todayLondonIso: '2026-05-20',
      );
      expect(snap.claimStreakBucket, '0');
    });

    test('streak with yesterday lastClaimDate still counts (not yet broken)',
        () {
      final snap = snapshotFromUserDoc(
        <String, dynamic>{
          'streak': 4,
          'lastClaimDate': '2026-05-19',
        },
        isAdmin: false,
        hasSeenIntro: true,
        todayLondonIso: '2026-05-20',
      );
      expect(snap.claimStreakBucket, '4-7');
    });

    test('toMap exposes every key in AnalyticsUserProps.all', () {
      final snap = snapshotFromUserDoc(
        <String, dynamic>{},
        isAdmin: false,
        hasSeenIntro: false,
        todayLondonIso: '2026-05-20',
      );
      final map = snap.toMap();
      expect(map.keys.toSet(), equals(AnalyticsUserProps.all.toSet()));
      // Every value is a non-null string.
      for (final v in map.values) {
        expect(v, isA<String>());
      }
    });
  });
}
