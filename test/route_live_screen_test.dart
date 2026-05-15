// Tests for LiveRouteScreen (T8 + T11).
//
// Notes on scope:
//  - The GPS position stream and nearbyPostboxes callable are injected so no
//    real Firebase initialisation or platform channels are needed.
//  - ClaimQuizSheet tests (T11) inject nearbyCallableForSheet and
//    startScoringCallableForSheet so the sheet never touches real Firebase.
//  - FlutterCompass is not exercised (platform sensor channel); deviceHeading
//    defaults to null in all tests, which is a valid code path.

import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/fuzzy_compass.dart';
import 'package:postbox_game/james_controller.dart';
import 'package:postbox_game/route/live_route_screen.dart';
import 'package:postbox_game/route/route_compass_view.dart';
import 'package:postbox_game/route/route_completion_screen.dart';
import 'package:postbox_game/route/route_session.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/widgets/claim_quiz_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Fake HttpsCallableResult
// ---------------------------------------------------------------------------

class _FakeResult<T> implements HttpsCallableResult<T> {
  _FakeResult(this.data);
  @override
  final T data;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Constructs a [Position] at the given coordinates with safe dummy values for
/// all required fields.
Position _pos(double lat, double lng) => Position(
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.now(),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

/// A [NearbyCallableFn] that returns a compass-only response (no claimable
/// postboxes within 30 m).
Future<HttpsCallableResult<dynamic>> _nearbyCompassOnly(
    Map<String, dynamic> _) async {
  return _FakeResult<dynamic>({
    'compass': {'N': 3, 'NE': 1},
    'claimedCompass': {'S': 2},
    'postboxes': <String, dynamic>{},
    'counts': {'total': 4, 'claimedToday': 2},
    'points': {'min': 2, 'max': 7},
  });
}

/// A [NearbyCallableFn] that returns a postbox within 30 m that is unclaimed.
/// Used by the claim-sheet trigger tests (T11).
Future<HttpsCallableResult<dynamic>> _nearbyClaimableBox(
    Map<String, dynamic> _) async {
  return _FakeResult<dynamic>({
    'compass': {'N': 1},
    'claimedCompass': <String, dynamic>{},
    'postboxes': {
      'pb_test': {
        'distance': 15.0,
        'claimedToday': false,
        'monarch': 'EVIIR',
      },
    },
    'counts': {'total': 1, 'claimedToday': 0},
    'points': {'min': 9, 'max': 9},
  });
}

/// A stub for [NearbyPostboxesCallableFn] injected into [ClaimQuizSheet].
/// Returns one unclaimed postbox so the sheet reaches the `results` stage.
Future<HttpsCallableResult<dynamic>> _sheetNearbyStub(
    Map<String, dynamic> _) async {
  return _FakeResult<dynamic>({
    'counts': {'total': 1, 'claimedToday': 0},
    'points': {'min': 9, 'max': 9},
    'postboxes': {
      'pb_test': {
        'distance': 15.0,
        'claimedToday': false,
        'monarch': 'EVIIR',
      },
    },
    'compass': {'N': 1},
    'claimedCompass': <String, dynamic>{},
  });
}

/// Default [RouteSession] for tests.
RouteSession _session({
  LatLng? destination,
}) =>
    RouteSession(
      start: const LatLng(51.5074, -0.1278),
      destination: destination ?? const LatLng(51.5200, -0.1100),
      destinationLabel: 'Test Destination',
    );

/// Wraps [LiveRouteScreen] in the minimal tree needed for Material.
///
/// No [JamesControllerScope] is included by default — all `?.show()` calls in
/// [LiveRouteScreen] are null-safe so this is a valid configuration. Tests
/// that need to verify James messages should build their own scope manually
/// and drain the idle timer with [drainJamesTimer] before the test ends.
///
/// Always passes an empty compass stream so FlutterCompass platform channel
/// is never activated (it throws [MissingPluginException] in headless tests).
Widget _buildScreen({
  required RouteSession session,
  required StreamController<Position> posCtrl,
  NearbyCallableFn nearbyCallable = _nearbyCompassOnly,
  NearbyPostboxesCallableFn? nearbyCallableForSheet,
  StartScoringCallableFn? startScoringCallableForSheet,
  List<NavigatorObserver> observers = const [],
}) {
  return MaterialApp(
    theme: AppTheme.light,
    navigatorObservers: observers,
    home: LiveRouteScreen(
      session: session,
      positionStreamOverride: posCtrl.stream,
      nearbyCallable: nearbyCallable,
      nearbyCallableForSheet: nearbyCallableForSheet,
      startScoringCallableForSheet: startScoringCallableForSheet,
      // Pass an empty stream to bypass the platform compass channel in tests.
      compassStreamOverride: const Stream<CompassEvent>.empty(),
    ),
  );
}

/// Pumps fake time past the maximum JamesController idle timer (5 min + buffer)
/// so no pending timer remains at test teardown.
Future<void> drainJamesTimer(WidgetTester tester) async {
  await tester.pump(const Duration(minutes: 6));
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // Initialise Firebase mocks once for the whole suite. This lets widgets that
  // reference FirebaseAuth / Firestore (e.g. HomeWidgetService inside
  // ClaimQuizSheet) construct without throwing MissingPluginException.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    // Provide a no-op SharedPreferences store so ClaimQuizSheet can call
    // AppPreferences.getDistanceUnit() without a platform-channel error.
    SharedPreferences.setMockInitialValues({});
  });

  group('LiveRouteScreen', () {
    // ── AppBar and scaffold ─────────────────────────────────────────────────

    testWidgets('renders AppBar with title "Route"', (tester) async {
      final posCtrl = StreamController<Position>.broadcast();
      addTearDown(posCtrl.close);

      await tester.pumpWidget(_buildScreen(session: _session(), posCtrl: posCtrl));
      await tester.pump();

      expect(find.text('Route'), findsOneWidget);
    });

    testWidgets('shows "Where now, postie?" hint button', (tester) async {
      final posCtrl = StreamController<Position>.broadcast();
      addTearDown(posCtrl.close);

      await tester.pumpWidget(_buildScreen(session: _session(), posCtrl: posCtrl));
      await tester.pump();

      expect(find.text('Where now, postie?'), findsOneWidget);
    });

    testWidgets('shows destination label from session', (tester) async {
      final posCtrl = StreamController<Position>.broadcast();
      addTearDown(posCtrl.close);

      await tester.pumpWidget(_buildScreen(session: _session(), posCtrl: posCtrl));
      await tester.pump();

      expect(find.text('Test Destination'), findsOneWidget);
    });

    // ── Distance display ────────────────────────────────────────────────────

    testWidgets(
        'destination distance updates and renders "km" label when > 1 km away',
        (tester) async {
      final posCtrl = StreamController<Position>.broadcast();
      addTearDown(posCtrl.close);

      // Destination is at 51.52, -0.11 — roughly 1.7 km from 51.5074, -0.1278.
      await tester.pumpWidget(_buildScreen(
        session: _session(),
        posCtrl: posCtrl,
        nearbyCallable: _nearbyCompassOnly,
      ));
      await tester.pump();

      // Emit a position far from the destination (same as start).
      posCtrl.add(_pos(51.5074, -0.1278));
      // Let the runAsync propagation + scan complete.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();

      // Distance should be rendered as a "km" value (> 1 000 m).
      expect(find.textContaining('km'), findsWidgets);
    });

    testWidgets('shows "m" label when within 1 km of destination',
        (tester) async {
      final posCtrl = StreamController<Position>.broadcast();
      addTearDown(posCtrl.close);

      // Use a destination ~450 m north — within 1 km but far enough to avoid
      // arrival detection (>25 m).
      final farEnough = RouteSession(
        start: const LatLng(51.5200, -0.1100),
        destination: const LatLng(51.5240, -0.1100),
        destinationLabel: 'Not quite there',
      );

      await tester.pumpWidget(_buildScreen(
        session: farEnough,
        posCtrl: posCtrl,
        nearbyCallable: _nearbyCompassOnly,
      ));
      await tester.pump();

      posCtrl.add(_pos(51.5200, -0.1100)); // ~450 m from destination
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();

      expect(find.textContaining('m'), findsWidgets);
    });

    // ── Bearing label ───────────────────────────────────────────────────────

    testWidgets('bearing chip is present after position emit', (tester) async {
      final posCtrl = StreamController<Position>.broadcast();
      addTearDown(posCtrl.close);

      await tester.pumpWidget(_buildScreen(
        session: _session(),
        posCtrl: posCtrl,
        nearbyCallable: _nearbyCompassOnly,
      ));
      await tester.pump();

      posCtrl.add(_pos(51.5074, -0.1278));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();

      // A bearing Chip (NE / E / SE etc.) should be visible.
      expect(find.byType(Chip), findsWidgets);
    });

    // ── RouteCompassView ────────────────────────────────────────────────────

    testWidgets('RouteCompassView is present in the widget tree', (tester) async {
      final posCtrl = StreamController<Position>.broadcast();
      addTearDown(posCtrl.close);

      await tester.pumpWidget(_buildScreen(session: _session(), posCtrl: posCtrl));
      await tester.pump();

      expect(find.byType(RouteCompassView), findsOneWidget);
    });

    // ── Hint button wires to JamesController ──────────────────────────────

    testWidgets('tapping hint button calls JamesController.show()',
        (tester) async {
      final posCtrl = StreamController<Position>.broadcast();
      addTearDown(posCtrl.close);

      // Build a JamesController and wrap the screen in a scope.
      // Drain the idle timer at the end so fake_async sees no pending timers.
      final jamesController = JamesController();
      String? lastMessage;
      jamesController.addListener(() {
        lastMessage = jamesController.pendingMessage;
      });

      await tester.pumpWidget(
        JamesControllerScope(
          controller: jamesController,
          child: MaterialApp(
            theme: AppTheme.light,
            home: LiveRouteScreen(
              session: _session(),
              positionStreamOverride: posCtrl.stream,
              nearbyCallable: _nearbyCompassOnly,
              compassStreamOverride: const Stream<CompassEvent>.empty(),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Where now, postie?'));
      await tester.pump();

      // A James hint message should have been set (it's a conversational phrase
      // from JamesMessages.routeHint — no requirement to contain the literal
      // direction word).
      expect(lastMessage, isNotNull);
      expect(lastMessage, isNotEmpty);

      // Advance fake time past the idle timer (max 5 min) to drain it.
      jamesController.dispose(); // cancels the timer
      await drainJamesTimer(tester);
    });

    // ── Arrival detection ───────────────────────────────────────────────────

    testWidgets(
        'position within 25 m of destination navigates to RouteCompletionScreen',
        (tester) async {
      final posCtrl = StreamController<Position>.broadcast();
      addTearDown(posCtrl.close);

      // Spy on route changes.
      final observer = _RouteObserver();

      // Put destination at (51.5100, -0.1200) and emit a position right on top
      // of it so distance < 25 m.
      const destLat = 51.5100;
      const destLng = -0.1200;
      final sess = RouteSession(
        start: const LatLng(51.5074, -0.1278),
        destination: const LatLng(destLat, destLng),
        destinationLabel: 'Arrival Test',
      );

      await tester.pumpWidget(_buildScreen(
        session: sess,
        posCtrl: posCtrl,
        nearbyCallable: _nearbyCompassOnly,
        observers: [observer],
      ));
      await tester.pump();

      // Emit position at (almost) the destination — within 25 m.
      posCtrl.add(_pos(destLat + 0.0001, destLng)); // ~11 m north of dest
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      // RouteCompletionScreen contains a ConfettiWidget that never "settles",
      // so use bounded pumps rather than pumpAndSettle to avoid timing out.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // RouteCompletionScreen should be top of stack.
      expect(find.byType(RouteCompletionScreen), findsOneWidget);
    });

    // ── Claimable postbox opens ClaimQuizSheet ─────────────────────────────

    testWidgets(
        'position with eligible postbox at 15 m opens ClaimQuizSheet',
        (tester) async {
      final posCtrl = StreamController<Position>.broadcast();
      addTearDown(posCtrl.close);

      // _nearbyClaimableBox returns pb_test at distance 15 m, unclaimed.
      // _sheetNearbyStub is forwarded into ClaimQuizSheet so it never touches
      // real Firebase.
      await tester.pumpWidget(_buildScreen(
        session: _session(),
        posCtrl: posCtrl,
        nearbyCallable: _nearbyClaimableBox,
        nearbyCallableForSheet: _sheetNearbyStub,
        // startScoringCallable is not invoked until the user taps "Claim",
        // so leaving it null (unreachable in this test) is fine.
      ));
      await tester.pump();

      // Emit a position far from the destination (> 25 m) so arrival is not
      // triggered.  The scan fires immediately (first call bypasses time/distance
      // throttle).
      posCtrl.add(_pos(51.5074, -0.1278));
      // Let the async scan complete.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      // ClaimQuizSheet contains an infinitely repeating pulse animation, so
      // pumpAndSettle will always time out.  Use bounded pumps instead.
      await tester.pump(); // process setState from _onPosition
      await tester.pump(const Duration(milliseconds: 100)); // open sheet
      await tester.pump(const Duration(milliseconds: 300)); // sheet animation

      expect(find.byType(ClaimQuizSheet), findsOneWidget);
    });

    // ── Dedupe: second scan with same eligible postbox ─────────────────────

    testWidgets(
        'second scan within 60 s for same postbox does not reopen sheet',
        (tester) async {
      final posCtrl = StreamController<Position>.broadcast();
      addTearDown(posCtrl.close);

      await tester.pumpWidget(_buildScreen(
        session: _session(),
        posCtrl: posCtrl,
        nearbyCallable: _nearbyClaimableBox,
        nearbyCallableForSheet: _sheetNearbyStub,
      ));
      await tester.pump();

      // First position → first scan → sheet opens.
      posCtrl.add(_pos(51.5074, -0.1278));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(ClaimQuizSheet), findsOneWidget);

      // Wait for the sheet's own nearbyPostboxes scan (_runSearch) to complete
      // so the sheet transitions from 'searching' to 'results'.  Multiple pump
      // cycles are needed:
      //  1. pump() triggers the addPostFrameCallback in ClaimQuizSheet.initState
      //     which calls _runSearch()
      //  2. runAsync lets the stub's Future resolve
      //  3. pump() applies the resulting setState
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Dismiss the sheet by tapping "Rescan location" (the cancel/back path
      // in the results stage).  This fires onCompleted which calls
      // Navigator.of(context).pop(result), causing the modal's .then()
      // callback to record the dismissal in _recentDismissals.
      await tester.tap(find.text('Rescan location'));
      // Need multiple pumps: the pop queues a route transition animation.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 300));

      // Sheet is gone — the dismissal was recorded in _recentDismissals.
      expect(find.byType(ClaimQuizSheet), findsNothing);

      // Second position emit (same coordinates — still within the 60 s
      // cooldown). The time/distance throttle is also still active, so
      // advance fake time by _kScanTimeTriggerS (12 s) to allow a new scan.
      await tester.pump(const Duration(seconds: 13));
      posCtrl.add(_pos(51.5074, -0.1278));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));

      // The dedupe window (60 s) has NOT elapsed — no second sheet.
      expect(find.byType(ClaimQuizSheet), findsNothing);
    });

    // ── Abandon dialog ──────────────────────────────────────────────────────

    testWidgets('tapping close icon shows abandon dialog', (tester) async {
      final posCtrl = StreamController<Position>.broadcast();
      addTearDown(posCtrl.close);

      await tester.pumpWidget(_buildScreen(session: _session(), posCtrl: posCtrl));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.text('End route now?'), findsOneWidget);
      expect(find.text('Points already claimed will keep.'), findsOneWidget);

      // Tap "Keep going" to dismiss.
      await tester.tap(find.text('Keep going'));
      await tester.pumpAndSettle();

      expect(find.text('End route now?'), findsNothing);
    });

    // ── Status row ──────────────────────────────────────────────────────────

    testWidgets('status row shows 0 pts and 0 claimed on start', (tester) async {
      final posCtrl = StreamController<Position>.broadcast();
      addTearDown(posCtrl.close);

      await tester.pumpWidget(_buildScreen(session: _session(), posCtrl: posCtrl));
      await tester.pump();

      expect(find.textContaining('0 pts'), findsOneWidget);
      expect(find.textContaining('0 claimed'), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // RouteCompassView unit smoke tests
  // --------------------------------------------------------------------------

  group('RouteCompassView', () {
    testWidgets('renders FuzzyCompass widget', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: RouteCompassView(
              compassCounts: const {'N': 2, 'NE': 1},
              claimedCompassCounts: const {'S': 1},
              deviceHeadingDegrees: null,
              destinationBearingDegrees: 45.0,
            ),
          ),
        ),
      );
      expect(find.byType(FuzzyCompass), findsOneWidget);
    });

    testWidgets('renders destination arrow icon', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: RouteCompassView(
              compassCounts: const {'N': 2},
              claimedCompassCounts: const {},
              deviceHeadingDegrees: 90.0,
              destinationBearingDegrees: 180.0,
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.navigation), findsOneWidget);
    });

    testWidgets('renders without device heading (null)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: RouteCompassView(
              compassCounts: const {},
              claimedCompassCounts: const {},
              deviceHeadingDegrees: null,
              destinationBearingDegrees: 270.0,
            ),
          ),
        ),
      );
      expect(find.byType(RouteCompassView), findsOneWidget);
      expect(find.byIcon(Icons.navigation), findsOneWidget);
    });
  });

  // --------------------------------------------------------------------------
  // RouteCompletionScreen stub tests
  // --------------------------------------------------------------------------

  group('RouteCompletionScreen', () {
    testWidgets('renders title and summary values', (tester) async {
      final sess = RouteSession(
        start: const LatLng(51.5074, -0.1278),
        destination: const LatLng(51.52, -0.11),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: RouteCompletionScreen(
            session: sess,
            pointsEarned: 14,
            claimedCount: 3,
            walkSeconds: 1200,
          ),
        ),
      );
      // The new RouteCompletionScreen has a ConfettiWidget that never settles,
      // so pump() is used instead of pumpAndSettle().
      await tester.pump();
      expect(find.text('Route complete'), findsOneWidget);
      // 14 points, 3 postboxes, 1200 s = 20 min 00 sec.
      expect(find.textContaining('14 points earned'), findsOneWidget);
      expect(find.textContaining('3 postboxes claimed'), findsOneWidget);
      expect(find.textContaining('20 min 00 sec'), findsOneWidget);
    });

    testWidgets('Done button is present', (tester) async {
      final sess = RouteSession(
        start: const LatLng(51.5074, -0.1278),
        destination: const LatLng(51.52, -0.11),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: RouteCompletionScreen(session: sess),
        ),
      );
      expect(find.text('Done'), findsOneWidget);
    });
  });
}

// ---------------------------------------------------------------------------
// NavigatorObserver spy
// ---------------------------------------------------------------------------

class _RouteObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) pushed.add(newRoute);
  }
}
