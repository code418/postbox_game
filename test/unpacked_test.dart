import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/postman_james.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/unpacked/unpacked_banner.dart';
import 'package:postbox_game/unpacked/unpacked_repository.dart';
import 'package:postbox_game/unpacked/unpacked_screen.dart';
import 'package:postbox_game/unpacked/unpacked_share_card.dart';
import 'package:postbox_game/unpacked/unpacked_stats.dart';
import 'package:postbox_game/unpacked/uk_county_map.dart';
import 'package:postbox_game/widgets/share_card.dart' show kShareLinkUrl;

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
      'availableFrom': '2026-12-19',
      'availableUntil': '2027-01-15',
    };

/// A snapshot with every field the builder writes, as of the review pass.
Map<String, dynamic> _fullSnapshot() => {
      ..._snapshot(),
      'monarchCounts': {
        'EIIR': 50,
        'GR': 12,
        'NONE': 9,
        'GVR': 7,
        'GVIR': 6,
        'VR': 4,
        'SCOTTISH_CROWN': 3,
        'EVIIR': 2,
        'CIIIR': 1,
        'EVIIIR': 1,
      },
      'busiestDays': [
        {'date': '2026-06-20', 'claims': 9, 'points': 38},
        {'date': '2026-04-03', 'claims': 7, 'points': 16},
        {'date': '2026-08-01', 'claims': 5, 'points': 22},
      ],
      'monthCounts': [1, 0, 2, 8, 3, 31, 4, 6, 2, 1, 0, 0],
      'weekdayPoints': [10, 4, 0, 6, 12, 142, 30],
      'countyBoxes': {'Bristol': 9, 'Somerset': 2},
      'rarestFind': {
        'postboxId': 'osm_1',
        'monarch': 'VR',
        'points': 7,
        'dailyDate': '2026-04-03',
        'reference': 'BS1 23',
        'county': 'Bristol',
      },
      'otherCounties': [
        {'name': 'Somerset', 'uniquePostboxes': 2, 'otherPlayers': 6},
      ],
      'favouritePostboxes': [
        {
          'claims': 41,
          'monarch': 'VR',
          'reference': 'BS8 102',
          'county': 'Bristol'
        },
        {'claims': 9, 'monarch': null, 'reference': null, 'county': 'Somerset'},
      ],
      'friendStreaks': [
        {'uid': 'sam', 'days': 21},
        {'uid': 'gone', 'days': 30},
        {'uid': 'alex', 'days': 3},
      ],
      'friendAwards': [
        {'uid': 'sam', 'daysActive': 143, 'uniquePostboxes': 300},
        {'uid': 'alex', 'daysActive': 40, 'uniquePostboxes': 90},
      ],
      'topScorerDays': {'friends': 12, 'everyone': 0},
    };

Map<String, dynamic> _fullSummary() => {
      ..._summary(),
      'uniquePostboxes': 9840,
      'totalClaims': 15200,
      'highlights': {
        'countiesCovered': 63,
        'rarestCypher': {'monarch': 'EVIIIR', 'boxes': 4},
        'longestStreak': 87,
        'busiestDay': {'date': '2026-06-20', 'claims': 412},
        'daysWithClaims': 298,
        'daysSoFar': 335,
        'sharedCounties': ['Bristol', 'Kent'],
      },
    };

/// The full recap, with "gone" (a deleted friend) missing from the names.
UnpackedRecap _fullRecap({Map<String, dynamic>? stats}) => UnpackedRecap(
      summary: UnpackedSummary.fromMap(_fullSummary(), year: 2026),
      stats: UnpackedStats.fromMap(stats ?? _fullSnapshot(), year: 2026),
      friendNames: const {'sam': 'Sam', 'alex': 'Alex'},
    );

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
      expect(s.isOpenOn('2026-12-18'), isFalse);
      expect(s.isOpenOn('2026-12-19'), isTrue);
      expect(s.isOpenOn('2027-01-15'), isTrue);
      expect(s.isOpenOn('2027-01-16'), isFalse);
    });

    test('a summary without window fields falls back to 19 Dec - 15 Jan', () {
      final s = UnpackedSummary.fromMap(const {}, year: 2026);
      expect(s.availableFrom, '2026-12-19');
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
      String today = '2026-12-20',
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
      expect(await repo(today: '2026-12-18').load('me'), isNull);
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
        today: () => '2026-12-20',
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

    test('a single postbox, point and day read in the singular', () {
      final totals = buildUnpackedCards(_recap(
        stats: {
          ..._snapshot(boxes: 1),
          'totalPoints': 1,
          'daysActive': 1,
        },
      )).firstWhere((c) => c.id == 'totals');
      expect(unpackedPlainText(totals.headline), '1 postbox');
      expect(unpackedPlainText(totals.detail!),
          startsWith('1 point across 1 day out and about.'));
    });

    test('percentile lines only appear when they flatter', () {
      final high =
          buildUnpackedCards(_recap()).firstWhere((c) => c.id == 'totals');
      expect(unpackedPlainText(high.detail!),
          contains('More postboxes than 87% of players.'));

      final low = buildUnpackedCards(_recap(
        stats: {
          ..._snapshot(),
          'percentiles': {'uniquePostboxes': 20}
        },
      )).firstWhere((c) => c.id == 'totals');
      expect(unpackedPlainText(low.detail!), isNot(contains('%')));
    });
  });

  group('copy', () {
    test('the share text carries the generic share link, not an invite', () {
      final text = unpackedShareText(2026);
      expect(text, startsWith('My 2026 Postboxes Unpacked'));
      expect(text, endsWith('Claim your postboxes: $kShareLinkUrl'));
      expect(text, isNot(contains('/invite/')));
    });

    test('the nudge does not call the player "postie" (that is the guide)', () {
      final nudge = JamesMessages.unpackedNudge(2026);
      expect(nudge, contains('2026 Postboxes Unpacked'));
      expect(nudge.toLowerCase(), isNot(contains('postie')));
      expect(nudge, isNot(contains('\u2014')));
    });
  });

  group('UnpackedScreen', () {
    Future<void> pumpScreen(WidgetTester tester,
        {Size physicalSize = const Size(1080, 2340)}) async {
      tester.view.physicalSize = physicalSize;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MediaQuery(
        // Reduced motion: no auto-advance timer, so the test drives every
        // transition explicitly.
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
            theme: AppTheme.light, home: UnpackedScreen(recap: _recap())),
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
          theme: AppTheme.light,
          home: UnpackedScreen(
            uid: 'me',
            repository: UnpackedRepository(
              firestore: db,
              config: RemoteConfigService(
                  remoteConfig: _StubRemoteConfig(unpackedEnabled: true)),
              isAdmin: () async => false,
              today: () => '2026-12-20',
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
        theme: AppTheme.light,
        home: UnpackedScreen(
          uid: 'me',
          repository: UnpackedRepository(
            firestore: FakeFirebaseFirestore(),
            config: RemoteConfigService(
                remoteConfig: _StubRemoteConfig(unpackedEnabled: true)),
            isAdmin: () async => false,
            today: () => '2026-12-20',
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining("isn't ready yet"), findsOneWidget);
    });
  });

  group('UnpackedScreen in landscape', () {
    testWidgets('every card, and the share page, fit a landscape phone',
        (tester) async {
      // 780 x 360 logical: a phone on its side, the tightest height the app
      // allows.
      tester.view.physicalSize = const Size(2340, 1080);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MediaQuery(
        data:
            const MediaQueryData(size: Size(780, 360), disableAnimations: true),
        child: MaterialApp(
            theme: AppTheme.light, home: UnpackedScreen(recap: _recap())),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'intro card');
      for (var i = 0; i < 8; i++) {
        await tester.tap(find.bySemanticsLabel('Next card'));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'card ${i + 2}');
      }
      expect(find.text('Share my year'), findsOneWidget);
    });
  });

  group('UnpackedShareCard', () {
    testWidgets('a one-day "streak" is left off the card', (tester) async {
      Future<void> pumpCard(int streakDays) async {
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          home: Center(
            child: UnpackedShareCard(
              stats: UnpackedStats.fromMap({
                ..._snapshot(),
                'longestStreak': {'days': streakDays},
              }, year: 2026),
            ),
          ),
        ));
      }

      await pumpCard(1);
      expect(find.text('LONGEST STREAK'), findsNothing);
      await pumpCard(5);
      expect(find.text('LONGEST STREAK'), findsOneWidget);
      expect(find.text('5 days'), findsOneWidget);
    });

    testWidgets('lays out at its fixed export size without overflow',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
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
      expect(find.text('1,234'), findsOneWidget);
      expect(find.text('More postboxes than 87% of players'), findsOneWidget);
      // Nothing drew outside the fixed export frame.
      expect(
          tester.getRect(find.text('1,234')).bottom,
          lessThanOrEqualTo(
              tester.getRect(find.byType(UnpackedShareCard)).bottom));
    });
  });

  group('review pass: new fields', () {
    test('parses every new snapshot and summary field', () {
      final r = _fullRecap();
      final s = r.stats;
      expect(s.busiestDays.map((d) => d.date),
          ['2026-06-20', '2026-04-03', '2026-08-01']);
      expect(s.monthCounts, hasLength(12));
      expect(s.weekdayPoints, [10, 4, 0, 6, 12, 142, 30]);
      expect(s.countyBoxes, {'Bristol': 9, 'Somerset': 2});
      expect(s.rarestCounty, 'Bristol');
      expect(s.otherCounties.single.otherPlayers, 6);
      expect(s.favouritePostboxes.last.monarch, MonarchInfo.plainKey);
      expect(s.friendUids, {'sam', 'gone', 'alex'});
      expect(s.topFriendsDays, 12);
      expect(s.topEveryoneDays, 0);
      final h = r.summary.highlights!;
      expect(h.rarestCypher, 'EVIIIR');
      expect(h.sharedCounties, ['Bristol', 'Kent']);
    });

    test('an older snapshot still parses: one busiest day, no charts', () {
      final s = UnpackedStats.fromMap(_snapshot(), year: 2026);
      expect(s.busiestDays.single.date, '2026-04-03');
      expect(s.monthCounts, isEmpty);
      expect(s.weekdayPoints, isEmpty);
      expect(s.friendStreaks, isEmpty);
      expect(
          UnpackedSummary.fromMap(_summary(), year: 2026).highlights, isNull);
    });

    test('a chart field of the wrong length is ignored', () {
      final s = UnpackedStats.fromMap({
        ..._snapshot(),
        'weekdayPoints': [1, 2, 3]
      }, year: 2026);
      expect(s.weekdayPoints, isEmpty);
    });
  });

  group('review pass: cards', () {
    test('a full recap tells the whole story, in order', () {
      expect(buildUnpackedCards(_fullRecap()).map((c) => c.id), [
        'intro',
        'totals',
        'rarest',
        'monarchs',
        'month',
        'weekday',
        'streak',
        'top',
        'county',
        'favourite',
        'community',
        'award',
        'share',
      ]);
    });

    UnpackedCardData card(String id, [UnpackedRecap? recap]) =>
        buildUnpackedCards(recap ?? _fullRecap()).firstWhere((c) => c.id == id);

    test('counts use thousands separators', () {
      expect(unpackedPlainText(card('community').headline), '9,840 postboxes');
    });

    test('"Together" drops the most-claimed cypher', () {
      final c = card('community');
      expect(unpackedPlainText(c.detail!),
          'Found by you and 39 other players this year, across 63 counties.');
      expect(c.detail, isNot(contains('most-claimed')));
    });

    test('the month card no longer repeats the favourite weekday', () {
      expect(unpackedPlainText(card('month').detail!), '8 claims that month.');
    });

    test('the weekday card leads with the best day for points', () {
      final c = card('weekday');
      expect(c.headline, 'Saturdays');
      expect(unpackedPlainText(c.detail!),
          '142 points on Saturdays, more than any other day of the week.');
    });

    test('no weekday or top-scorer card without the data', () {
      final ids = buildUnpackedCards(_recap()).map((c) => c.id);
      expect(ids, isNot(contains('weekday')));
      expect(ids, isNot(contains('top')));
      expect(ids, isNot(contains('award')));
      expect(ids, isNot(contains('favourite')));
    });

    test('the award is inaugural in 2026 and dated after', () {
      expect(card('award').headline, 'The Inaugural\nMike H Award');
      final later = _fullSnapshot()..['year'] = 2027;
      final r = UnpackedRecap(
        summary: UnpackedSummary.fromMap(_fullSummary(), year: 2027),
        stats: UnpackedStats.fromMap(later, year: 2027),
        friendNames: const {'sam': 'Sam'},
      );
      expect(card('award', r).headline, 'The 2027\nMike H Award');
    });

    test('the award needs a friend whose name loaded', () {
      final r = UnpackedRecap(
        summary: UnpackedSummary.fromMap(_fullSummary(), year: 2026),
        stats: UnpackedStats.fromMap(_fullSnapshot(), year: 2026),
      );
      final ids = buildUnpackedCards(r).map((c) => c.id);
      expect(ids, isNot(contains('award')));
    });

    test('the favourite postbox card names the box and where it is', () {
      final c = card('favourite');
      expect(c.headline, 'Box BS8 102');
      expect(
          unpackedPlainText(c.detail!),
          'Claimed on 41 days. Victoria (1837–1901), in Bristol. '
          'Nobody else claimed it all year.');
    });
  });

  group('review pass: the guide', () {
    test('the rarest-find line plays down a common Elizabeth II', () {
      for (var i = 0; i < 30; i++) {
        expect(JamesMessages.unpackedRarest('EIIR'),
            matches(RegExp(r'\b(not|hardly)\b', caseSensitive: false)));
      }
    });

    test('rarer cyphers get their own lines', () {
      final common = {
        for (var i = 0; i < 30; i++) JamesMessages.unpackedRarest('EIIR')
      };
      for (final m in ['VR', 'EVIIR', 'CIIIR', 'EVIIIR', 'GR']) {
        for (var i = 0; i < 10; i++) {
          expect(common, isNot(contains(JamesMessages.unpackedRarest(m))));
        }
      }
      expect(JamesMessages.unpackedRarest('EVIIIR'), contains('Edward VIII'));
    });

    test('the Together line', () {
      expect(
          JamesMessages.unpackedCommunity.resolve(),
          "Brings a tear to my eye to see so many claimed. I couldn't do any "
          "of this without you, and when I say 'this' I mean 'not much in "
          "the scheme of things'");
    });

    testWidgets('the long Together line still fits a small phone',
        (tester) async {
      tester.view.physicalSize = const Size(1125, 2001); // iPhone SE
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MediaQuery(
        data:
            const MediaQueryData(size: Size(375, 667), disableAnimations: true),
        child: MaterialApp(
            theme: AppTheme.light,
            home: UnpackedScreen(recap: _fullRecap(), today: '2026-12-20')),
      ));
      await tester.pump();
      for (var i = 0; i < 14 && find.text('TOGETHER').evaluate().isEmpty; i++) {
        await tester.tap(find.bySemanticsLabel('Next card'));
        await tester.pump();
      }
      expect(find.textContaining('Brings a tear'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // The last of the stats stays clear of the guide's bubble.
      expect(tester.getRect(find.text('DAYS WITH A CLAIM')).bottom,
          lessThan(tester.getRect(find.textContaining('Brings a tear')).top));
    });

    test('the favourite-postbox line', () {
      expect(JamesMessages.unpackedFavourite(41),
          '41 claims! There are many slots out there, but this one is yours.');
    });

    test('the totals line pays a penny a postbox', () {
      expect(JamesMessages.unpackedTotals(142),
          'Cor! If I had a penny for every postbox you claimed, I would have £1.42');
      expect(JamesMessages.pennies(1), 'a penny');
      expect(JamesMessages.pennies(42), '42p');
      expect(JamesMessages.pennies(100), '£1');
      expect(JamesMessages.pennies(105), '£1.05');
      expect(JamesMessages.pennies(123456), '£1,234.56');
    });

    test('the new lines follow the house rules', () {
      final lines = [
        for (final m in ['EIIR', 'GR', 'VR', 'EVIIR', 'CIIIR', 'EVIIIR'])
          for (var i = 0; i < 10; i++) JamesMessages.unpackedRarest(m),
        for (final p in [0, 1, 2, 3]) JamesMessages.unpackedAward(p),
        for (final d in [1, 9, 41]) JamesMessages.unpackedFavourite(d),
        JamesMessages.unpackedWeekday('Saturday'),
        JamesMessages.unpackedWeekday('Tuesday'),
        JamesMessages.unpackedTopScorer(everyone: true),
        JamesMessages.unpackedTopScorer(everyone: false),
        for (final n in [1, 42, 142, 123456]) JamesMessages.unpackedTotals(n),
        JamesMessages.unpackedCommunity.resolve(),
      ];
      for (final l in lines) {
        expect(l, isNot(contains('\u2014')), reason: l);
        expect(l, isNot(contains('James')), reason: l);
      }
    });
  });

  group('review pass: friend names', () {
    test('the repository looks names up and drops deleted friends', () async {
      final db = FakeFirebaseFirestore();
      await db.collection('unpacked').doc('2026').set(_fullSummary());
      await db
          .collection('unpacked')
          .doc('2026')
          .collection('players')
          .doc('me')
          .set(_fullSnapshot());
      await db.collection('users').doc('sam').set({'displayName': ' Sam '});
      await db.collection('users').doc('alex').set({'displayName': ''});
      // "gone" has no user doc: the account was deleted.
      final r = await UnpackedRepository(
        firestore: db,
        config: RemoteConfigService(
            remoteConfig: _StubRemoteConfig(unpackedEnabled: true)),
        isAdmin: () async => false,
        today: () => '2026-12-20',
      ).load('me');
      expect(r!.friendNames, {'sam': 'Sam', 'alex': 'A friend'});
    });
  });

  group('review pass: screen', () {
    Future<void> pump(WidgetTester tester, UnpackedRecap recap,
        {Size size = const Size(1080, 2340), bool reduceMotion = true}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MediaQuery(
        data: MediaQueryData(size: size / 3, disableAnimations: reduceMotion),
        child: MaterialApp(
            theme: AppTheme.light, home: UnpackedScreen(recap: recap)),
      ));
      await tester.pump();
    }

    Future<void> tapTo(WidgetTester tester, String text) async {
      for (var i = 0; i < 14 && find.text(text).evaluate().isEmpty; i++) {
        await tester.tap(find.bySemanticsLabel('Next card'));
        await tester.pump();
      }
      expect(find.text(text), findsWidgets);
    }

    testWidgets('the roll-call lists every cypher, and fits a small phone',
        (tester) async {
      // An iPhone SE: 375 x 667.
      await pump(tester, _fullRecap(), size: const Size(1125, 2001));
      await tapTo(tester, 'YOUR ROYAL ROLL-CALL');
      final guide = tester.getRect(find.byType(PostmanJames).first);
      expect(find.text('9 of 9 cyphers'), findsOneWidget);
      expect(find.text('Plus 9 plain boxes with no cypher.'), findsOneWidget);
      for (final key in _fullSnapshot()['monarchCounts'].keys) {
        if (key == 'NONE') continue; // a footnote, not a bar
        final label = MonarchInfo.labels[key]!;
        expect(find.text(label), findsOneWidget, reason: label);
        expect(tester.getRect(find.text(label)).bottom,
            lessThanOrEqualTo(guide.top),
            reason: '$label is hidden behind the guide');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('streak friends and the award podium show names, not uids',
        (tester) async {
      await pump(tester, _fullRecap());
      await tapTo(tester, 'YOUR LONGEST STREAK');
      expect(find.text('Sam'), findsOneWidget);
      expect(find.text('You'), findsOneWidget);
      expect(find.text('gone'), findsNothing);
      await tapTo(tester, 'AND NOW, THE AWARDS');
      // Sam 143 days, Alex 40, you 15: you take bronze.
      expect(find.bySemanticsLabel(RegExp(r'^Gold: Sam, 143 days')),
          findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Bronze: You, 15 days')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('every card of a full recap fits in landscape', (tester) async {
      await pump(tester, _fullRecap(), size: const Size(2340, 1080));
      for (var i = 0; i < 12; i++) {
        expect(tester.takeException(), isNull, reason: 'card ${i + 1}');
        await tester.tap(find.bySemanticsLabel('Next card'));
        await tester.pump();
      }
      expect(find.text('Share my year'), findsOneWidget);
    });

    testWidgets('counts run up from 0 as a card comes in', (tester) async {
      await pump(tester, _recap(), reduceMotion: false);
      await tester.tap(find.bySemanticsLabel('Next card'));
      await tester.pump();
      expect(find.text('0 postboxes'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1500));
      expect(find.text('12 postboxes'), findsOneWidget);
      // Leave nothing running.
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('reduced motion shows the final numbers at once',
        (tester) async {
      await pump(tester, _recap());
      await tester.tap(find.bySemanticsLabel('Next card'));
      await tester.pump();
      expect(find.text('12 postboxes'), findsOneWidget);
    });
  });

  group('county names', () {
    test('the cards drop the ONS "City of" / "County of" tail', () {
      expect(countyDisplayName('Bristol, City of'), 'Bristol');
      expect(countyDisplayName('Kingston upon Hull, City of'),
          'Kingston upon Hull');
      expect(countyDisplayName('Herefordshire, County of'), 'Herefordshire');
      expect(countyDisplayName('City of Edinburgh'), 'City of Edinburgh');
      expect(countyDisplayName('Newry, Mourne and Down'),
          'Newry, Mourne and Down');
    });
  });

  group('UkCountyMap', () {
    test('county names match whatever their punctuation', () {
      expect(countyKey('Bristol, City of'), 'bristol-city-of');
      expect(countyKey('  Kingston upon Hull, City of '),
          'kingston-upon-hull-city-of');
    });
  });

  group('review pass: the Christmas post', () {
    final summary = UnpackedSummary.fromMap(_summary(), year: 2026);

    test('the cut-off is the eve of the window opening', () {
      expect(
          unpackedChristmasPost('2026-11-25', summary), ChristmasPost.before);
      expect(
          unpackedChristmasPost('2026-12-18', summary), ChristmasPost.before);
      expect(unpackedChristmasPost('2026-12-19', summary),
          ChristmasPost.firstClass);
      expect(unpackedChristmasPost('2026-12-21', summary),
          ChristmasPost.firstClass);
      expect(unpackedChristmasPost('2026-12-22', summary),
          ChristmasPost.lastMinute);
      expect(unpackedChristmasPost('2026-12-24', summary),
          ChristmasPost.lastMinute);
      expect(unpackedChristmasPost('2026-12-25', summary), ChristmasPost.after);
      expect(unpackedChristmasPost('2027-01-10', summary), ChristmasPost.after);
    });

    UnpackedCardData intro(String today, {bool complete = true}) =>
        buildUnpackedCards(
          _recap(stats: {
            ..._snapshot(),
            'throughDate': complete ? '2026-12-18' : '2026-11-20',
            'complete': complete,
          }),
          today: today,
        ).first;

    test('the final recap says what it counts', () {
      expect(
          intro('2026-12-20').detail,
          'Your year up to Friday 18 December, the last day for second-class '
          'Christmas post.');
      expect(intro('2026-11-20', complete: false).detail,
          'Your year so far, up to 20 November.');
    });

    test('the guide hurries the Christmas cards along, then stops', () {
      expect(intro('2026-12-20').james,
          contains('first-class stamp by Monday 21 December'));
      expect(intro('2026-12-22').james, contains('hand-deliver'));
      expect(intro('2026-12-24').james, contains('hand-deliver'));
      expect(intro('2026-11-20', complete: false).james,
          contains('Friday 18 December'));
      expect(intro('2026-12-28').james, isNot(contains('Christmas')));
      for (final d in [
        '2026-11-20',
        '2026-12-20',
        '2026-12-24',
        '2026-12-28'
      ]) {
        expect(intro(d).james, isNot(contains('\u2014')));
      }
    });
  });

  group('final pass', () {
    UnpackedCardData card(String id, {Map<String, dynamic>? stats}) =>
        buildUnpackedCards(_fullRecap(stats: stats), today: '2026-12-20')
            .firstWhere((c) => c.id == id);

    test('the roll-call is a collection with plain boxes as a footnote', () {
      final c = card('monarchs', stats: {
        ..._fullSnapshot(),
        'monarchCounts': {'EIIR': 104, 'GR': 22, 'NONE': 20, 'VR': 8},
      });
      expect(unpackedPlainText(c.headline), '3 of 9 cyphers');
      expect(c.detail, isNull);
      final full = card('monarchs');
      expect(unpackedPlainText(full.headline), '9 of 9 cyphers');
      expect(full.detail, 'The full set! Every cypher collected.');
    });

    test('cypher short names drop the reign dates only', () {
      expect(cypherShortName('EVIIIR'), 'Edward VIII');
      expect(cypherShortName('CIIIR'), 'Charles III');
      expect(cypherShortName('GR'), 'George (generic)');
      expect(
          cypherShortName('SCOTTISH_CROWN'), 'Scottish Crown (Scotland only)');
    });

    test('Home turf says how many of your boxes were there', () {
      final c = card('county', stats: {
        ..._fullSnapshot(),
        'uniquePostboxes': 142,
        'topCounty': {'name': 'Bristol, City of', 'uniquePostboxes': 88},
        'countiesVisited': 4,
      });
      expect(c.headline, 'Bristol');
      expect(unpackedPlainText(c.detail!),
          '88 of your 142 postboxes were here. You hunted in 4 counties.');
      final all = card('county', stats: {
        ..._fullSnapshot(),
        'uniquePostboxes': 9,
        'topCounty': {'name': 'Kent', 'uniquePostboxes': 9},
        'countiesVisited': 1,
      });
      expect(
          unpackedPlainText(all.detail!), 'All 9 of your postboxes were here.');
    });

    test('Days at the top says whose table it was', () {
      expect(
          unpackedPlainText(card('top', stats: {
            ..._fullSnapshot(),
            'topScorerDays': {'friends': 14, 'everyone': 3},
          }).detail!),
          'Top among your friends on 14 days, and top of everyone on 3!');
      expect(unpackedPlainText(card('top').detail!),
          'Top among your friends on 12 days.');
      final everyone = card('top', stats: {
        ..._fullSnapshot(),
        'topScorerDays': {'friends': 0, 'everyone': 2},
      });
      expect(unpackedPlainText(everyone.headline), '2 days');
      expect(unpackedPlainText(everyone.detail!),
          'Top of everyone who played on 2 days!');
    });

    test('streaks and the rarest find carry their dates', () {
      expect(unpackedPlainText(card('streak').detail!),
          startsWith('From 1 to 5 April.'));
      final across = card('streak', stats: {
        ..._fullSnapshot(),
        'longestStreak': {
          'days': 12,
          'start': '2026-05-28',
          'end': '2026-06-08'
        },
      });
      expect(unpackedPlainText(across.detail!),
          startsWith('From 28 May to 8 June.'));
      expect(unpackedPlainText(card('rarest').detail!),
          'Worth 7 points (box BS1 23). Found on Friday 3 April.');
    });

    test('the favourite postbox knows its number one fan', () {
      String detail(Map<String, dynamic> fav) => unpackedPlainText(card(
            'favourite',
            stats: {
              ..._fullSnapshot(),
              'favouritePostboxes': [
                {'claims': 41, 'monarch': 'VR', 'reference': 'BS8 7', ...fav},
              ],
            },
          ).detail!);
      expect(detail({'fans': 6, 'topFan': true}),
          endsWith('Nobody claimed it more than you.'));
      expect(detail({'fans': 1, 'topFan': true}),
          endsWith('Nobody else claimed it all year.'));
      expect(detail({'fans': 6, 'topFan': false}),
          endsWith('Victoria (1837–1901).'));
    });

    test('the award field ranks friends and finds the player', () {
      final a = unpackedAward(_fullRecap())!;
      expect(a.field.map((e) => e.name), ['Sam', 'Alex', 'You']);
      expect(a.place, 2);
      expect(unpackedMedal(a.place), 'Bronze');
      expect(unpackedMedal(3), isNull);
    });

    testWidgets('the podium puts an off-podium player underneath',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final stats = {
        ..._fullSnapshot(),
        'friendAwards': [
          {'uid': 'sam', 'daysActive': 143, 'uniquePostboxes': 300},
          {'uid': 'alex', 'daysActive': 40, 'uniquePostboxes': 90},
          {'uid': 'kim', 'daysActive': 30, 'uniquePostboxes': 60},
        ],
      };
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          theme: AppTheme.light,
          home: UnpackedScreen(
            today: '2026-12-20',
            recap: UnpackedRecap(
              summary: UnpackedSummary.fromMap(_fullSummary(), year: 2026),
              stats: UnpackedStats.fromMap(stats, year: 2026),
              friendNames: const {'sam': 'Sam', 'alex': 'Alex', 'kim': 'Kim'},
            ),
          ),
        ),
      ));
      await tester.pump();
      for (var i = 0;
          i < 14 && find.text('AND NOW, THE AWARDS').evaluate().isEmpty;
          i++) {
        await tester.tap(find.bySemanticsLabel('Next card'));
        await tester.pump();
      }
      expect(
          find.text('You came 4th, with 15 days out hunting.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the share image names the cypher and shows a medal',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Center(
          child: UnpackedShareCard(
            stats: UnpackedStats.fromMap({
              ..._snapshot(),
              'rarestFind': {'monarch': 'EVIIIR', 'points': 12}
            }, year: 2026),
            medal: 'Silver',
          ),
        ),
      ));
      expect(find.text('Edward VIII'), findsOneWidget);
      expect(find.text('EVIIIR'), findsNothing);
      expect(find.text('MIKE H AWARD'), findsOneWidget);
      expect(find.text('Silver'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the ready banner opens or dismisses, under the real theme',
        (tester) async {
      var opened = 0, dismissed = 0;
      for (final theme in [AppTheme.light, AppTheme.dark]) {
        await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: Scaffold(
            body: UnpackedReadyBanner(
              year: 2026,
              onOpen: () => opened++,
              onDismiss: () => dismissed++,
            ),
          ),
        ));
        expect(
            find.text('Your 2026 Postboxes Unpacked is ready'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Open'));
        await tester.tap(find.byTooltip('Dismiss'));
      }
      expect(opened, 2);
      expect(dismissed, 2);
      expect(unpackedBannerDoneKey(2026), 'unpacked_banner_done_2026');
    });
  });
}
