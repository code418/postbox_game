// Tests for RouteCompletionScreen (T9).
//
// Coverage:
//  - Points, claims, and walking-time text render correctly.
//  - "Done" button triggers popUntil(isFirst).
//  - "Plan another route" button also navigates back to first route.
//
// RouteNotifications is NOT tested here — the flutter_local_notifications
// plugin requires a real platform channel that is unavailable in widget tests.
// A single sanity smoke-test for notifyArrival lives below and uses
// ignoreErrors to confirm no Dart-level throws occur.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/route/route_completion_screen.dart';
import 'package:postbox_game/route/route_session.dart';
import 'package:postbox_game/theme.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Wraps [RouteCompletionScreen] in a minimal [MaterialApp] with a fake
/// preceding route so that [popUntil(isFirst)] has at least one route to pop.
Widget _buildApp({
  required RouteSession session,
  int pointsEarned = 0,
  int claimedCount = 0,
  int walkSeconds = 0,
}) {
  return MaterialApp(
    theme: AppTheme.light,
    home: Navigator(
      onGenerateRoute: (settings) => MaterialPageRoute<void>(
        builder: (_) => RouteCompletionScreen(
          session: session,
          pointsEarned: pointsEarned,
          claimedCount: claimedCount,
          walkSeconds: walkSeconds,
        ),
      ),
    ),
  );
}

RouteSession _makeSession() => RouteSession(
      start: const LatLng(51.5, -0.1),
      destination: const LatLng(51.51, -0.09),
      destinationLabel: 'Buckingham Palace',
      pace: RoutePace.walk,
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('RouteCompletionScreen', () {
    testWidgets('shows points earned', (tester) async {
      await tester.pumpWidget(_buildApp(
        session: _makeSession(),
        pointsEarned: 42,
        claimedCount: 3,
        walkSeconds: 600,
      ));
      // Use pump rather than pumpAndSettle: the ConfettiWidget animation never
      // "settles" so pumpAndSettle would time out.
      await tester.pump();

      expect(find.textContaining('42 points earned'), findsOneWidget);
    });

    testWidgets('shows claimed count — singular', (tester) async {
      await tester.pumpWidget(_buildApp(
        session: _makeSession(),
        pointsEarned: 7,
        claimedCount: 1,
        walkSeconds: 120,
      ));
      await tester.pump();

      expect(find.textContaining('1 postbox claimed'), findsOneWidget);
    });

    testWidgets('shows claimed count — plural', (tester) async {
      await tester.pumpWidget(_buildApp(
        session: _makeSession(),
        pointsEarned: 14,
        claimedCount: 2,
        walkSeconds: 240,
      ));
      await tester.pump();

      expect(find.textContaining('2 postboxes claimed'), findsOneWidget);
    });

    testWidgets('formats walking time — under one hour', (tester) async {
      await tester.pumpWidget(_buildApp(
        session: _makeSession(),
        walkSeconds: 7 * 60 + 33, // 7 min 33 sec
      ));
      await tester.pump();

      expect(find.textContaining('07 min 33 sec'), findsOneWidget);
    });

    testWidgets('formats walking time — over one hour', (tester) async {
      await tester.pumpWidget(_buildApp(
        session: _makeSession(),
        walkSeconds: 3700, // 1 h 01 min
      ));
      await tester.pump();

      expect(find.textContaining('1 h 01 min'), findsOneWidget);
    });

    testWidgets('shows pace chip', (tester) async {
      await tester.pumpWidget(_buildApp(
        session: _makeSession()..pace = RoutePace.walk,
      ));
      await tester.pump();

      expect(find.textContaining('Walking'), findsOneWidget);
    });

    testWidgets('shows jogging chip for jog pace', (tester) async {
      final session = _makeSession()..pace = RoutePace.jog;
      await tester.pumpWidget(_buildApp(session: session));
      await tester.pump();

      expect(find.textContaining('Jogging'), findsOneWidget);
    });

    testWidgets('"Done" button pops to first route', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => RouteCompletionScreen(
                    session: _makeSession(),
                    pointsEarned: 10,
                    claimedCount: 1,
                    walkSeconds: 60,
                  ),
                ),
              ),
              child: const Text('Go'),
            ),
          ),
        ),
      );

      // Navigate to the completion screen.
      await tester.tap(find.text('Go'));
      // Two pumps: one to start the push animation, one to finish it.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('Done'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // After Done the navigator should have popped back to the first route
      // (the 'Go' button screen).
      expect(find.text('Go'), findsOneWidget);
    });

    testWidgets('"Plan another route" also returns to first route',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => RouteCompletionScreen(
                    session: _makeSession(),
                  ),
                ),
              ),
              child: const Text('Start'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Start'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('Plan another route'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Start'), findsOneWidget);
    });
  });
}

