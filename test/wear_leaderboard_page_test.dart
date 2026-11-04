// The watch leaderboard glance.
//
// The stale-periodKey guard is the important one: the backend resets a period
// document's entries lazily (newDayScoreboard at midnight London, or the first
// claim of the day), so between midnight and that reset the document still
// holds YESTERDAY's rankings under yesterday's key. A watch checked first thing
// in the morning is exactly when that would show — the phone discards them for
// the same reason in leaderboard_screen.dart.

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/london_date.dart';
import 'package:postbox_game/wear/wear_leaderboard_page.dart';
import 'package:postbox_game/wear/wear_theme.dart';

Map<String, dynamic> board(String periodKey, List<Map<String, dynamic>> e) =>
    <String, dynamic>{'periodKey': periodKey, 'entries': e};

Map<String, dynamic> entry(String uid, String name, int points) =>
    <String, dynamic>{'uid': uid, 'displayName': name, 'points': points};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseWearLeaderboard', () {
    final today = todayLondon();

    test('ranks entries in stored order, flagging the signed-in user', () {
      final rows = parseWearLeaderboard(
        data: board(today, [
          entry('a', 'Ann', 30),
          entry('me', 'Me', 20),
          entry('c', 'Cal', 10),
        ]),
        period: 'daily',
        today: today,
        myUid: 'me',
      );
      expect(rows.map((r) => r.rank), [1, 2, 3]);
      expect(rows.map((r) => r.displayName), ['Ann', 'Me', 'Cal']);
      expect(rows.map((r) => r.points), [30, 20, 10]);
      expect(rows.map((r) => r.isMe), [false, true, false]);
    });

    test('a stale periodKey discards the whole board', () {
      final rows = parseWearLeaderboard(
        data: board('1999-01-01', [entry('a', 'Ann', 30)]),
        period: 'daily',
        today: today,
        myUid: 'me',
      );
      expect(rows, isEmpty);
    });

    test('weekly and monthly use their own key shapes', () {
      final weekly = parseWearLeaderboard(
        data: board(expectedPeriodKey('weekly', today)!, [
          entry('a', 'Ann', 5),
        ]),
        period: 'weekly',
        today: today,
      );
      expect(weekly, hasLength(1));

      // The same document read as a DAILY board must be discarded — the keys
      // are differently shaped, so a mismatch is not a coincidence.
      final asDaily = parseWearLeaderboard(
        data: board(expectedPeriodKey('weekly', today)!, [
          entry('a', 'Ann', 5),
        ]),
        period: 'daily',
        today: today,
      );
      expect(asDaily, isEmpty);
    });

    test('survives a malformed document', () {
      expect(parseWearLeaderboard(data: null, period: 'daily', today: today),
          isEmpty);
      final rows = parseWearLeaderboard(
        data: <String, dynamic>{
          'periodKey': today,
          'entries': <dynamic>['not a map', entry('a', 'Ann', 3)],
        },
        period: 'daily',
        today: today,
      );
      expect(rows, hasLength(1));
      expect(rows.single.displayName, 'Ann');
    });

    test('missing fields fall back rather than throwing', () {
      final rows = parseWearLeaderboard(
        data: <String, dynamic>{
          'periodKey': today,
          'entries': <dynamic>[<String, dynamic>{}],
        },
        period: 'daily',
        today: today,
      );
      expect(rows.single.displayName, 'Unknown');
      expect(rows.single.points, 0);
      expect(rows.single.isMe, isFalse);
    });
  });

  group('WearLeaderboardView', () {
    Future<void> pump(WidgetTester tester, Widget view) async {
      await tester.pumpWidget(MaterialApp(theme: WearTheme.dark, home: view));
      await tester.pump();
    }

    testWidgets('shows only the top three', (tester) async {
      await pump(
        tester,
        WearLeaderboardView(
          period: 'daily',
          entries: List.generate(
            8,
            (i) => WearLeaderboardEntry(
                rank: i + 1,
                displayName: 'Player$i',
                points: 100 - i,
                isMe: false),
          ),
          onCyclePeriod: () {},
        ),
      );
      expect(find.text('Player0'), findsOneWidget);
      expect(find.text('Player2'), findsOneWidget);
      expect(find.text('Player3'), findsNothing);
    });

    testWidgets('adds a "You" row when the user is outside the top three',
        (tester) async {
      await pump(
        tester,
        WearLeaderboardView(
          period: 'daily',
          entries: [
            ...List.generate(
                3,
                (i) => WearLeaderboardEntry(
                    rank: i + 1,
                    displayName: 'Player$i',
                    points: 100 - i,
                    isMe: false)),
            const WearLeaderboardEntry(
                rank: 12, displayName: 'Me', points: 8, isMe: true),
          ],
          onCyclePeriod: () {},
        ),
      );
      expect(find.text('You'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.text('8'), findsOneWidget);
    });

    testWidgets('does not repeat the user when already in the top three',
        (tester) async {
      await pump(
        tester,
        WearLeaderboardView(
          period: 'daily',
          entries: const [
            WearLeaderboardEntry(
                rank: 1, displayName: 'Ann', points: 30, isMe: false),
            WearLeaderboardEntry(
                rank: 2, displayName: 'Me', points: 20, isMe: true),
          ],
          onCyclePeriod: () {},
        ),
      );
      expect(find.text('You'), findsOneWidget);
    });

    testWidgets('empty and loading states', (tester) async {
      await pump(
        tester,
        WearLeaderboardView(
            period: 'daily', entries: const [], onCyclePeriod: () {}),
      );
      expect(find.text('No scores yet'), findsOneWidget);

      await pump(
        tester,
        WearLeaderboardView(
            period: 'daily', entries: null, onCyclePeriod: () {}),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('tapping the title cycles daily -> weekly -> monthly',
        (tester) async {
      var taps = 0;
      await pump(
        tester,
        WearLeaderboardView(
            period: 'daily', entries: const [], onCyclePeriod: () => taps++),
      );
      await tester.tap(find.text('Today'));
      expect(taps, 1);

      // The labels the cycle walks through.
      expect(kWearLeaderboardPeriods, ['daily', 'weekly', 'monthly']);
      expect(wearPeriodLabel('daily'), 'Today');
      expect(wearPeriodLabel('weekly'), 'This week');
      expect(wearPeriodLabel('monthly'), 'This month');
    });
  });

  group('WearLeaderboardPage', () {
    testWidgets('streams the period document and cycles on a title tap',
        (tester) async {
      final firestore = FakeFirebaseFirestore();
      final today = todayLondon();
      await firestore
          .collection('leaderboards')
          .doc('daily')
          .set(board(today, [entry('me', 'Me', 42)]));
      await firestore.collection('leaderboards').doc('weekly').set(
          board(expectedPeriodKey('weekly', today)!, [entry('a', 'Ann', 99)]));

      await tester.pumpWidget(MaterialApp(
        theme: WearTheme.dark,
        home: WearLeaderboardPage(firestore: firestore, uid: 'me'),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Today'), findsOneWidget);
      expect(find.text('You'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);

      await tester.tap(find.text('Today'));
      await tester.pumpAndSettle();
      expect(find.text('This week'), findsOneWidget);
      expect(find.text('Ann'), findsOneWidget);
      expect(find.text('99'), findsOneWidget);
    });
  });
}
