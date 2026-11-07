import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/unpacked/unpacked_repository.dart';
import 'package:postbox_game/unpacked/unpacked_screen.dart';
import 'package:postbox_game/unpacked/unpacked_share_card.dart';
import 'package:postbox_game/unpacked/unpacked_stats.dart';

// "Your Postboxes Unpacked" (December annual recap): snapshot parsing, the
// availability gate (Remote Config flag + window + admin soft launch), which
// story cards a snapshot produces, and the story screen's tap navigation.

class _StubRemoteConfig extends Fake implements FirebaseRemoteConfig {
  _StubRemoteConfig({this.unpackedEnabled = false});
  final bool unpackedEnabled;
  @override
  bool getBool(String key) =>
      key == RemoteConfigService.keyUnpackedEnabled && unpackedEnabled;
  @override
  String getString(String key) => '';
}

class _FakeAnalytics extends Fake implements FirebaseAnalytics {
  final events = <String>[];
  @override
  Future<void> logEvent({
    required String name,
    Map<String, Object>? parameters,
    List<AnalyticsEventItem>? items,
    AnalyticsCallOptions? callOptions,
  }) async =>
      events.add(name);
}

Map<String, dynamic> _snapshot({int boxes = 12}) => {
      'year': 2026,
      'totalClaims': 20,
      'uniquePostboxes': boxes,
      'totalPoints': 64,
      'daysActive': 15,
      'firstClaimDate': '2026-01-04',
      'throughDate': '2026-12-01',
      'longestStreak': {'days': 5, 'start': '2026-04-01', 'end': '2026-04-05'},
      'busiestMonth': {'month': 4, 'claims': 8},
      'favouriteWeekday': {'weekday': 6, 'claims': 7},
      'busiestDay': {'date': '2026-04-03', 'points': 16, 'claims': 3},
      'rarestFind': {
        'postboxId': 'osm_1',
        'monarch': 'VR',
        'points': 7,
        'dailyDate': '2026-04-03',
        'reference': 'BS1 23',
      },
      'monarchCounts': {'EIIR': 12, 'VR': 2, 'NONE': 6},
      'topCounty': {'name': 'Bristol', 'uniquePostboxes': 9},
      'countiesVisited': 3,
      'percentiles': {
        'uniquePostboxes': 87,
        'totalPoints': 80,
        'longestStreak': 40
      },
    };

Map<String, dynamic> _summary({int players = 40}) => {
      'year': 2026,
      'players': players,
      'totalClaims': 900,
      'uniquePostboxes': 610,
      'totalPoints': 2400,
      'topMonarch': 'GR',
      'availableFrom': '2026-12-01',
      'availableUntil': '2027-01-15',
    };

UnpackedRecap _recap({Map<String, dynamic>? stats, int players = 40}) =>
    UnpackedRecap(
      summary: UnpackedSummary.fromMap(_summary(players: players), year: 2026),
      stats: UnpackedStats.fromMap(stats ?? _snapshot(), year: 2026),
    );

void main() {
  setUp(() {
    Analytics.instance = _FakeAnalytics();
    RemoteConfigService.instance =
        RemoteConfigService(remoteConfig: _StubRemoteConfig());
  });
  tearDown(RemoteConfigService.resetForTest);

  group('UnpackedStats.fromMap', () {
    test('parses a full snapshot', () {
      final s = UnpackedStats.fromMap(_snapshot(), year: 2026);
      expect(s.uniquePostboxes, 12);
      expect(s.longestStreakDays, 5);
      expect(s.busiestMonth, 4);
      expect(s.favouriteWeekday, 6);
      expect(s.rarestMonarch, 'VR');
      expect(s.rarestReference, 'BS1 23');
      expect(s.topCountyName, 'Bristol');
      expect(s.percentileBoxes, 87);
      // Sorted most-claimed first; the server's NONE becomes the display
      // plain key.
      expect(s.monarchCounts.map((e) => e.key).toList(),
          ['EIIR', MonarchInfo.plainKey, 'VR']);
    });

    test('tolerates missing and malformed fields', () {
      final s = UnpackedStats.fromMap(<String, dynamic>{
        'totalClaims': 1,
        'uniquePostboxes': 'lots',
        'busiestMonth': {'month': 13},
        'percentiles': {'uniquePostboxes': 250},
      }, year: 2026);
      expect(s.year, 2026);
      expect(s.uniquePostboxes, 0);
      expect(s.busiestMonth, 0);
      expect(s.rarestMonarch, isNull);
      expect(s.topCountyName, isNull);
      expect(s.monarchCounts, isEmpty);
      expect(s.percentileBoxes, 99);
      expect(s.isEmpty, isFalse);
    });

    test('a plain-box rarest find maps to the plain key', () {
      final s = UnpackedStats.fromMap({
        'totalClaims': 1,
        'rarestFind': {'monarch': null, 'points': 2},
      }, year: 2026);
      expect(s.rarestMonarch, MonarchInfo.plainKey);
    });
  });

  group('window + year helpers', () {
    test('unpackedYearFor maps December forward and January back', () {
      expect(unpackedYearFor('2026-12-01'), 2026);
      expect(unpackedYearFor('2027-01-15'), 2026);
    });

    test('summary window is inclusive at both ends', () {
      final s = UnpackedSummary.fromMap(_summary(), year: 2026);
      expect(s.isOpenOn('2026-11-30'), isFalse);
      expect(s.isOpenOn('2026-12-01'), isTrue);
      expect(s.isOpenOn('2027-01-15'), isTrue);
      expect(s.isOpenOn('2027-01-16'), isFalse);
    });

    test('a summary without window fields falls back to 1 Dec - 15 Jan', () {
      final s = UnpackedSummary.fromMap(const {}, year: 2026);
      expect(s.availableFrom, '2026-12-01');
      expect(s.availableUntil, '2027-01-15');
    });
  });

  group('UnpackedRepository.load', () {
    late FakeFirebaseFirestore db;

    setUp(() async {
      db = FakeFirebaseFirestore();
      await db.collection('unpacked').doc('2026').set(_summary());
      await db
          .collection('unpacked')
          .doc('2026')
          .collection('players')
          .doc('me')
          .set(_snapshot());
    });

    UnpackedRepository repo({
      bool flag = true,
      bool admin = false,
      String today = '2026-12-05',
    }) =>
        UnpackedRepository(
          firestore: db,
          config: RemoteConfigService(
              remoteConfig: _StubRemoteConfig(unpackedEnabled: flag)),
          isAdmin: () async => admin,
          today: () => today,
        );

    test('returns the recap when flag, window and snapshot all line up',
        () async {
      final r = await repo().load('me');
      expect(r, isNotNull);
      expect(r!.year, 2026);
      expect(r.stats.uniquePostboxes, 12);
      expect(r.summary.players, 40);
    });

    test('hidden while the Remote Config flag is off', () async {
      expect(await repo(flag: false).load('me'), isNull);
    });

    test('hidden outside the window', () async {
      expect(await repo(today: '2026-11-30').load('me'), isNull);
      expect(await repo(today: '2027-01-16').load('me'), isNull);
    });

    test('still shown in the January tail of the window', () async {
      expect(await repo(today: '2027-01-10').load('me'), isNotNull);
    });

    test('hidden for a player with no snapshot', () async {
      expect(await repo().load('someone-else'), isNull);
    });

    test('hidden for an empty snapshot', () async {
      await db
          .collection('unpacked')
          .doc('2026')
          .collection('players')
          .doc('empty')
          .set({'totalClaims': 0});
      expect(await repo().load('empty'), isNull);
    });

    test(
        'admins see it before the flag flips and before December (soft launch)',
        () async {
      final r =
          await repo(flag: false, admin: true, today: '2026-11-25').load('me');
      expect(r, isNotNull);
      expect(r!.year, 2026);
    });

    test('never throws: a failing admin lookup just hides the recap', () async {
      final r = UnpackedRepository(
        firestore: db,
        config: RemoteConfigService(
            remoteConfig: _StubRemoteConfig(unpackedEnabled: true)),
        isAdmin: () async => throw StateError('boom'),
        today: () => '2026-12-05',
      );
      expect(await r.load('me'), isNull);
    });
  });

  group('buildUnpackedCards', () {
    test('a full snapshot produces every card, in story order', () {
      final ids = buildUnpackedCards(_recap()).map((c) => c.id).toList();
      expect(ids, [
        'intro',
        'totals',
        'rarest',
        'monarchs',
        'month',
        'streak',
        'county',
        'community',
        'share',
      ]);
    });

    test('cards with no data are skipped', () {
      final ids = buildUnpackedCards(_recap(
        players: 1,
        stats: {
          'totalClaims': 1,
          'uniquePostboxes': 1,
          'totalPoints': 2,
          'daysActive': 1,
          'longestStreak': {'days': 1},
          'rarestFind': {'monarch': null, 'points': 2},
        },
      )).map((c) => c.id).toList();
      // A one-day streak, a plain-box "rarest" find, no county, no cyphers
      // and a field of one player all drop their cards.
      expect(ids, ['intro', 'totals', 'share']);
    });

    test('percentile lines only appear when they flatter', () {
      final high =
          buildUnpackedCards(_recap()).firstWhere((c) => c.id == 'totals');
      expect(high.detail, contains('More postboxes than 87% of players.'));

      final low = buildUnpackedCards(_recap(
        stats: {
          ..._snapshot(),
          'percentiles': {'uniquePostboxes': 20}
        },
      )).firstWhere((c) => c.id == 'totals');
      expect(low.detail, isNot(contains('%')));
    });
  });

  group('UnpackedScreen', () {
    Future<void> pumpScreen(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MediaQuery(
        // Reduced motion: no auto-advance timer, so the test drives every
        // transition explicitly.
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(home: UnpackedScreen(recap: _recap())),
      ));
      await tester.pump();
    }

    testWidgets('opens on the intro card and taps through to the share card',
        (tester) async {
      await pumpScreen(tester);
      expect(find.text('Your 2026\nPostboxes\nUnpacked'), findsOneWidget);
      expect((Analytics.instance as _FakeAnalytics).events,
          contains('unpacked_opened'));

      await tester.tap(find.bySemanticsLabel('Next card'));
      await tester.pump();
      expect(find.text('12 postboxes'), findsOneWidget);

      // Back from the left third.
      await tester.tap(find.bySemanticsLabel('Previous card'));
      await tester.pump();
      expect(find.text('Your 2026\nPostboxes\nUnpacked'), findsOneWidget);

      // Intro → totals → rarest → monarchs → month → streak → county →
      // community → share: eight taps.
      for (var i = 0; i < 8; i++) {
        await tester.tap(find.bySemanticsLabel('Next card'));
        await tester.pump();
      }
      expect(find.text('Share my year'), findsOneWidget);
      expect(find.byType(UnpackedShareCard), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('loads the recap itself when opened without one (deep link)',
        (tester) async {
      final db = FakeFirebaseFirestore();
      await db.collection('unpacked').doc('2026').set(_summary());
      await db
          .collection('unpacked')
          .doc('2026')
          .collection('players')
          .doc('me')
          .set(_snapshot());
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: UnpackedScreen(
            uid: 'me',
            repository: UnpackedRepository(
              firestore: db,
              config: RemoteConfigService(
                  remoteConfig: _StubRemoteConfig(unpackedEnabled: true)),
              isAdmin: () async => false,
              today: () => '2026-12-05',
            ),
          ),
        ),
      ));
      // James animates forever, so pump rather than settle.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Your 2026\nPostboxes\nUnpacked'), findsOneWidget);
    });

    testWidgets('shows a friendly message when no recap is available',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: UnpackedScreen(
          uid: 'me',
          repository: UnpackedRepository(
            firestore: FakeFirebaseFirestore(),
            config: RemoteConfigService(
                remoteConfig: _StubRemoteConfig(unpackedEnabled: true)),
            isAdmin: () async => false,
            today: () => '2026-12-05',
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining("isn't ready yet"), findsOneWidget);
    });
  });

  group('UnpackedShareCard', () {
    testWidgets('lays out at its fixed export size without overflow',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: UnpackedShareCard(
            stats: UnpackedStats.fromMap({
              ..._snapshot(boxes: 1234),
              'topCounty': {
                'name': 'The Very Long County Name of Somewhere-upon-Sea',
                'uniquePostboxes': 3,
              },
            }, year: 2026),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(UnpackedShareCard)),
          UnpackedShareCard.logicalSize);
      expect(find.text('1234'), findsOneWidget);
      expect(find.text('More postboxes than 87% of players'), findsOneWidget);
      // Nothing drew outside the fixed export frame.
      expect(
          tester.getRect(find.text('1234')).bottom,
          lessThanOrEqualTo(
              tester.getRect(find.byType(UnpackedShareCard)).bottom));
    });
  });
}
