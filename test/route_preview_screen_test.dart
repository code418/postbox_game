// Tests for RoutePreviewScreen.
//
// The routePostboxes callable is injected via the optional [callableFn]
// constructor parameter (a simple async function), so no real Firebase
// initialisation is needed here.

import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/route/route_preview_screen.dart';
import 'package:postbox_game/route/route_session.dart';
import 'package:postbox_game/theme.dart';

// ---------------------------------------------------------------------------
// Fake HttpsCallableResult
// ---------------------------------------------------------------------------

class _FakeCallableResult<T> implements HttpsCallableResult<T> {
  _FakeCallableResult(this.data);
  @override
  final T data;
}

// ---------------------------------------------------------------------------
// Stub callable function
// ---------------------------------------------------------------------------

class _CallCounter {
  int count = 0;
}

/// Returns a [RouteCallableFn] that yields [result] after an optional [delay],
/// incrementing [counter] on each invocation.
({RouteCallableFn fn, _CallCounter counter}) _makeStub({
  Map<String, dynamic>? result,
  FirebaseFunctionsException? error,
  Duration delay = Duration.zero,
}) {
  final counter = _CallCounter();
  Future<HttpsCallableResult<dynamic>> fn(Map<String, dynamic> _) async {
    counter.count++;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (error != null) throw error;
    return _FakeCallableResult<dynamic>(result ?? _successPayload());
  }

  return (fn: fn, counter: counter);
}

// ---------------------------------------------------------------------------
// Default successful payload
// ---------------------------------------------------------------------------

Map<String, dynamic> _successPayload({
  int count = 5,
  int points = 28,
  num directDistanceM = 2700,
  num budgetDistanceM = 2700,
  List<String> warnings = const [],
}) =>
    {
      'count': count,
      'points': points,
      'directDistanceM': directDistanceM,
      'budgetDistanceM': budgetDistanceM,
      'warnings': warnings,
    };

// ---------------------------------------------------------------------------
// Build helper
// ---------------------------------------------------------------------------

Widget _buildPreview({
  required RouteSession session,
  required RouteCallableFn callableFn,
}) {
  return MaterialApp(
    theme: AppTheme.light,
    home: RoutePreviewScreen(
      session: session,
      callableFn: callableFn,
    ),
  );
}

RouteSession _defaultSession() => RouteSession(
      start: const LatLng(51.5074, -0.1278),
      destination: const LatLng(51.52, -0.11),
      destinationLabel: 'Test Destination',
    );

/// Pumps through the initial fetch cycle when the callable resolves instantly.
///
/// Uses [WidgetTester.runAsync] so that the real async machinery (microtask
/// scheduling from an `async` function returning a resolved future) completes
/// before we pump the frame that renders the result.
Future<void> _pumpAndWait(WidgetTester tester) async {
  await tester.pump(); // build + initState schedules Timer(Duration.zero)
  await tester.pump(Duration.zero); // fire the zero-duration timer; _fetch starts
  // Let the async _fetch() complete: it awaits a Future that resolves
  // immediately, but 'await' still suspends to the next microtask.
  // runAsync drains real async work without the fake-async limitations.
  await tester.runAsync(() async {
    await Future<void>.delayed(Duration.zero);
  });
  await tester.pump(); // rebuild with result state
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('RoutePreviewScreen', () {
    testWidgets('shows AppBar with title "Route preview"', (tester) async {
      final (:fn, :counter) = _makeStub(result: _successPayload());
      await tester.pumpWidget(_buildPreview(session: _defaultSession(), callableFn: fn));
      await tester.pump();
      expect(find.text('Route preview'), findsOneWidget);
    });

    testWidgets(
        'shows postbox count and points after debounce settles with success response',
        (tester) async {
      final (:fn, :counter) =
          _makeStub(result: _successPayload(count: 5, points: 28));
      await tester.pumpWidget(
          _buildPreview(session: _defaultSession(), callableFn: fn));
      await _pumpAndWait(tester);

      // "5 unclaimed postboxes en-route" and "28 points" are rendered inside
      // RichText widgets, so we must pass findRichText: true.
      expect(find.textContaining('5', findRichText: true), findsWidgets);
      expect(find.textContaining('28', findRichText: true), findsWidgets);
    });

    testWidgets(
        'changing pace from Walk to Jog updates the time estimate label',
        (tester) async {
      final (:fn, :counter) = _makeStub(result: _successPayload());
      final session = _defaultSession();

      await tester.pumpWidget(_buildPreview(session: session, callableFn: fn));
      await _pumpAndWait(tester);

      // After a successful response, directDistanceM is set.
      // The time estimate should say "walking".
      expect(find.textContaining('walking'), findsOneWidget);

      // Tap the Jog segment.
      await tester.tap(find.text('Jog'));
      await tester.pump();

      // Time estimate label should now say "jogging".
      expect(find.textContaining('jogging'), findsOneWidget);
    });

    testWidgets(
        'changing the corridor slider re-triggers the callable',
        (tester) async {
      final (:fn, :counter) = _makeStub(result: _successPayload());
      final session = _defaultSession();

      await tester.pumpWidget(_buildPreview(session: session, callableFn: fn));
      await _pumpAndWait(tester);

      final callsAfterInit = counter.count;

      // Drag the first Slider (corridor slider).
      final sliderFinder = find.byType(Slider).first;
      await tester.drag(sliderFinder, const Offset(50, 0));
      // Wait for the 400 ms debounce to fire then the async call to complete.
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();

      expect(counter.count, greaterThan(callsAfterInit));
    });

    testWidgets(
        'slider change flips Start route to disabled before the debounce fires',
        (tester) async {
      // First call resolves immediately so the screen reaches the result
      // state with the button enabled; the second is held by a completer so
      // we can inspect the in-flight (post-slider, pre-fetch) state.
      var callIndex = 0;
      final secondCallCompleter = Completer<HttpsCallableResult<dynamic>>();
      Future<HttpsCallableResult<dynamic>> fn(Map<String, dynamic> _) {
        callIndex++;
        if (callIndex == 1) {
          return Future.value(_FakeCallableResult<dynamic>(_successPayload()));
        }
        return secondCallCompleter.future;
      }

      await tester
          .pumpWidget(_buildPreview(session: _defaultSession(), callableFn: fn));
      await _pumpAndWait(tester);

      // After the first response the button is enabled.
      expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Start route'))
            .onPressed,
        isNotNull,
      );

      // Drag the corridor slider. The debounce timer hasn't fired yet, but the
      // headline state must already have flipped to loading so the user can't
      // start a route whose headline is showing the previous params' figures.
      await tester.drag(find.byType(Slider).first, const Offset(50, 0));
      await tester.pump();

      expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Start route'))
            .onPressed,
        isNull,
        reason: 'Start route must be disabled while the new result is loading',
      );

      // Complete the held call so pending-timer assertions pass.
      await tester.pump(const Duration(milliseconds: 450));
      secondCallCompleter
          .complete(_FakeCallableResult<dynamic>(_successPayload()));
      await tester.pumpAndSettle();
    });

    testWidgets('shows error state when callable throws', (tester) async {
      final (:fn, :counter) = _makeStub(
        error: FirebaseFunctionsException(
          code: 'internal',
          message: 'Server error',
          details: null,
        ),
      );

      await tester.pumpWidget(
          _buildPreview(session: _defaultSession(), callableFn: fn));
      await _pumpAndWait(tester);

      // Warning icon and Retry button should appear.
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets(
        '"Start route" button is disabled until first successful response',
        (tester) async {
      // Use a completer so we control exactly when the callable resolves.
      final completer = Completer<HttpsCallableResult<dynamic>>();
      Future<HttpsCallableResult<dynamic>> fn(Map<String, dynamic> _) =>
          completer.future;

      await tester.pumpWidget(
          _buildPreview(session: _defaultSession(), callableFn: fn));
      await tester.pump(); // build + start timer
      await tester.pump(); // timer fires, _fetch starts but hasn't resolved

      // Before the response: button should be disabled.
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Start route'),
      );
      expect(button.onPressed, isNull,
          reason: 'Button must be disabled before any response arrives');

      // Complete to avoid pending timers warning.
      completer.complete(
          _FakeCallableResult<dynamic>(_successPayload()));
    });

    testWidgets(
        '"Start route" button is enabled after first successful response',
        (tester) async {
      final (:fn, :counter) = _makeStub(result: _successPayload());

      await tester.pumpWidget(
          _buildPreview(session: _defaultSession(), callableFn: fn));
      await _pumpAndWait(tester);

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Start route'),
      );
      expect(button.onPressed, isNotNull,
          reason: 'Button should be enabled after a successful response');
    });

    testWidgets('shows destination label in the destination card',
        (tester) async {
      final (:fn, :counter) = _makeStub(result: _successPayload());
      final session = RouteSession(
        start: const LatLng(51.5074, -0.1278),
        destination: const LatLng(51.52, -0.11),
        destinationLabel: 'Buckingham Palace',
      );

      await tester.pumpWidget(_buildPreview(session: session, callableFn: fn));
      await tester.pump();

      expect(find.text('Buckingham Palace'), findsOneWidget);
    });

    testWidgets('shows softer message when count == 0', (tester) async {
      final (:fn, :counter) =
          _makeStub(result: _successPayload(count: 0, points: 0));

      await tester.pumpWidget(
          _buildPreview(session: _defaultSession(), callableFn: fn));
      await _pumpAndWait(tester);

      expect(find.textContaining('Nothing along this route'), findsOneWidget);
    });

    testWidgets('shows loading indicator while callable is in-flight',
        (tester) async {
      // Use a completer so we control exactly when the callable resolves.
      final completer = Completer<HttpsCallableResult<dynamic>>();
      Future<HttpsCallableResult<dynamic>> fn(Map<String, dynamic> _) =>
          completer.future;

      await tester.pumpWidget(
          _buildPreview(session: _defaultSession(), callableFn: fn));
      // Advance past the Timer(Duration.zero) so _fetch fires and setState(loading)
      // is called, then pump one more frame so the rebuild happens.
      await tester.pump(Duration.zero); // fires the zero timer; _fetch calls setState(loading)
      await tester.pump(); // rebuilds with loading state

      // Loading state should be visible.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Calculating...'), findsOneWidget);

      // Complete to avoid pending timer warning.
      completer.complete(_FakeCallableResult<dynamic>(_successPayload()));
    });
  });
}
