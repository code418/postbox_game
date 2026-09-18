// The watch's "what have I claimed today" glance.
//
// The ClaimEvents refetch is the load-bearing bit: this page lives inside the
// shell's PageView and stays alive once built, so without that signal it would
// keep saying "No claims today" straight after a claim — the same staleness
// ClaimEvents was introduced to fix on the phone's History tab. The throttle is
// its counterweight: a watch page gets swiped past repeatedly, and each fetch
// is a Firestore join on the server.

import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/services/claim_events.dart';
import 'package:postbox_game/wear/wear_theme.dart';
import 'package:postbox_game/wear/wear_today_page.dart';

class _FakeResult<T> implements HttpsCallableResult<T> {
  _FakeResult(this.data);
  @override
  final T data;
}

Map<String, dynamic> _entry(String monarch, int points) => <String, dynamic>{
      'postboxId': 'osm_$monarch$points',
      'monarch': monarch,
      'timesClaimed': 1,
      'totalPoints': points,
    };

Map<String, dynamic> _payload(List<Map<String, dynamic>> entries) =>
    <String, dynamic>{'entries': entries, 'period': 'daily'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(ClaimEvents.resetForTest);

  group('parseWearToday', () {
    test('counts distinct boxes and sums the period points', () {
      final s = parseWearToday(_payload([
        _entry('VR', 7),
        _entry('EIIR', 2),
        _entry('GR', 4),
      ]));
      expect(s.boxes, 3);
      expect(s.points, 13);
      expect(s.isEmpty, isFalse);
      expect(s.claims.first.monarch, 'VR');
    });

    test('an empty day parses to an empty summary', () {
      final s = parseWearToday(_payload(const []));
      expect(s.boxes, 0);
      expect(s.points, 0);
      expect(s.isEmpty, isTrue);
    });

    test('survives a malformed payload', () {
      expect(parseWearToday(null).isEmpty, isTrue);
      expect(parseWearToday('nonsense').isEmpty, isTrue);
      final s = parseWearToday(<String, dynamic>{
        'entries': <dynamic>['not a map', _entry('VR', 7)],
      });
      expect(s.boxes, 1);
      expect(s.points, 7);
    });

    test('a missing monarch or points falls back rather than throwing', () {
      final s = parseWearToday(<String, dynamic>{
        'entries': <dynamic>[<String, dynamic>{}],
      });
      expect(s.boxes, 1);
      expect(s.points, 0);
      expect(s.claims.single.monarch, isNull);
    });
  });

  group('wearTodayErrorMessage', () {
    test('maps the codes a history fetch can actually return', () {
      expect(wearTodayErrorMessage('unavailable'), 'No connection.');
      expect(wearTodayErrorMessage('unauthenticated'), 'Sign in again');
      expect(wearTodayErrorMessage('internal'), 'Could not load');
    });

    test('every message is short enough for the inscribed square', () {
      for (final code in ['unavailable', 'unauthenticated', 'internal']) {
        expect(wearTodayErrorMessage(code).length, lessThanOrEqualTo(24));
      }
    });
  });

  group('WearTodayPage', () {
    Future<void> pump(
        WidgetTester tester, WearHistoryCallableFn callable) async {
      await tester.pumpWidget(MaterialApp(
        theme: WearTheme.dark,
        home: WearTodayPage(historyCallable: callable),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('renders the headline and the claimed ciphers', (tester) async {
      await pump(
          tester,
          (_) async => _FakeResult<dynamic>(
              _payload([_entry('VR', 7), _entry('GR', 4)])));

      expect(find.text('2 boxes · 11 pts'), findsOneWidget);
      expect(find.text('Victoria'), findsOneWidget);
      expect(find.text('George'), findsOneWidget);
    });

    testWidgets('singularises a one-box day', (tester) async {
      await pump(tester,
          (_) async => _FakeResult<dynamic>(_payload([_entry('VR', 7)])));
      expect(find.text('1 box · 7 pts'), findsOneWidget);
    });

    testWidgets('caps the cipher rows and counts the rest', (tester) async {
      await pump(
          tester,
          (_) async => _FakeResult<dynamic>(_payload([
                _entry('VR', 7),
                _entry('GR', 4),
                _entry('EIIR', 2),
                _entry('CIIIR', 9),
                _entry('EVIIR', 9),
              ])));
      expect(find.text('5 boxes · 31 pts'), findsOneWidget);
      expect(find.text('+2 more'), findsOneWidget);
    });

    testWidgets('empty state invites a walk', (tester) async {
      await pump(tester, (_) async => _FakeResult<dynamic>(_payload(const [])));
      expect(find.text('No claims today'), findsOneWidget);
      expect(find.text('Go find a postbox'), findsOneWidget);
    });

    testWidgets('a callable failure offers a retry', (tester) async {
      var calls = 0;
      await pump(tester, (_) async {
        calls++;
        if (calls == 1) {
          throw FirebaseFunctionsException(code: 'internal', message: 'boom');
        }
        return _FakeResult<dynamic>(_payload([_entry('VR', 7)]));
      });

      expect(find.text('Could not load'), findsOneWidget);
      expect(find.text('Tap to retry'), findsOneWidget);

      await tester.tap(find.byType(WearTodayView));
      await tester.pumpAndSettle();
      expect(find.text('1 box · 7 pts'), findsOneWidget);
    });

    testWidgets('a settled claim refetches, bypassing the throttle',
        (tester) async {
      var calls = 0;
      await pump(tester, (_) async {
        calls++;
        return _FakeResult<dynamic>(
            _payload(List.generate(calls, (i) => _entry('VR', 7))));
      });
      expect(calls, 1);
      expect(find.text('1 box · 7 pts'), findsOneWidget);

      ClaimEvents.markClaimed();
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.text('2 boxes · 14 pts'), findsOneWidget);
    });

    testWidgets('an unforced refresh inside the window is throttled',
        (tester) async {
      var calls = 0;
      await pump(tester, (_) async {
        calls++;
        return _FakeResult<dynamic>(_payload([_entry('VR', 7)]));
      });
      expect(calls, 1);

      // A tap forces, so drive the unforced path directly by rebuilding the
      // same state: the page must not refetch on every rebuild.
      await tester.pump();
      await tester.pump();
      expect(calls, 1);
    });

    testWidgets('shows a spinner on the very first load', (tester) async {
      final gate = Completer<HttpsCallableResult<dynamic>>();
      await tester.pumpWidget(MaterialApp(
        theme: WearTheme.dark,
        home: WearTodayPage(historyCallable: (_) => gate.future),
      ));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      gate.complete(_FakeResult<dynamic>(_payload([_entry('VR', 7)])));
      await tester.pumpAndSettle();
      expect(find.text('1 box · 7 pts'), findsOneWidget);
    });
  });
}
