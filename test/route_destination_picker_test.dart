// Tests for DestinationPickerScreen and RouteSession.
//
// Notes on scope:
//  - Gesture-based map taps are skipped: FlutterMap renders into a canvas and
//    does not expose widget-tree tap targets that flutter_test can find. The
//    onTap wiring is a one-liner verified by code review.
//  - The loading state and "button disabled until pin dropped" cases are
//    covered by injecting `initialPosition` so the screen bypasses the real
//    getPosition() call entirely.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/route/destination_picker_screen.dart';
import 'package:postbox_game/route/route_session.dart';
import 'package:postbox_game/theme.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Wraps the screen in the minimal widget tree required for MaterialApp theming.
Widget _buildPicker({LatLng? initialPosition}) {
  return MaterialApp(
    theme: AppTheme.light,
    home: DestinationPickerScreen(initialPosition: initialPosition),
  );
}

// ---------------------------------------------------------------------------
// RouteSession unit tests
// ---------------------------------------------------------------------------

void main() {
  group('RouteSession', () {
    test('defaults are applied correctly', () {
      final s = RouteSession(
        start: const LatLng(51.5, -0.1),
        destination: const LatLng(51.51, -0.11),
      );
      expect(s.mode, RouteMode.corridor);
      expect(s.corridorMetres, 200);
      expect(s.detourMinutes, 0);
      expect(s.pace, RoutePace.walk);
      expect(s.destinationLabel, isNull);
      expect(s.computedCount, isNull);
      expect(s.computedPoints, isNull);
      expect(s.directDistanceM, isNull);
    });

    test('speedKmh returns 4.5 for walk', () {
      final s = RouteSession(
        start: const LatLng(51.5, -0.1),
        destination: const LatLng(51.51, -0.11),
        pace: RoutePace.walk,
      );
      expect(s.speedKmh, 4.5);
    });

    test('speedKmh returns 8.5 for jog', () {
      final s = RouteSession(
        start: const LatLng(51.5, -0.1),
        destination: const LatLng(51.51, -0.11),
        pace: RoutePace.jog,
      );
      expect(s.speedKmh, 8.5);
    });

    test('corridorMetres is clamped to [50, 500]', () {
      final lo = RouteSession(
        start: const LatLng(51.5, -0.1),
        destination: const LatLng(51.51, -0.11),
        corridorMetres: 10,
      );
      expect(lo.corridorMetres, 50);

      final hi = RouteSession(
        start: const LatLng(51.5, -0.1),
        destination: const LatLng(51.51, -0.11),
        corridorMetres: 9999,
      );
      expect(hi.corridorMetres, 500);
    });

    test('detourMinutes is clamped to [0, 120]', () {
      final lo = RouteSession(
        start: const LatLng(51.5, -0.1),
        destination: const LatLng(51.51, -0.11),
        detourMinutes: -5,
      );
      expect(lo.detourMinutes, 0);

      final hi = RouteSession(
        start: const LatLng(51.5, -0.1),
        destination: const LatLng(51.51, -0.11),
        detourMinutes: 200,
      );
      expect(hi.detourMinutes, 120);
    });

    test('fields can be mutated directly (mutable by design)', () {
      final s = RouteSession(
        start: const LatLng(51.5, -0.1),
        destination: const LatLng(51.51, -0.11),
      );
      s.computedCount = 7;
      s.computedPoints = 42;
      s.directDistanceM = 1200;
      s.destinationLabel = 'The Pub';
      expect(s.computedCount, 7);
      expect(s.computedPoints, 42);
      expect(s.directDistanceM, 1200);
      expect(s.destinationLabel, 'The Pub');
    });
  });

  // ---------------------------------------------------------------------------
  // DestinationPickerScreen widget tests
  // ---------------------------------------------------------------------------

  group('DestinationPickerScreen', () {
    // The map plugin (flutter_map) needs tile rendering support; use
    // `pumpAndSettle` with a short timeout and ignore any async tile errors.

    testWidgets('shows CircularProgressIndicator while position is loading',
        (tester) async {
      // No initialPosition supplied → screen starts in loading state.
      // We do NOT call getPosition() because the screen only calls it when
      // initialPosition == null. In the test the screen is pumped once with
      // pump() (not pumpAndSettle) so initState fires but the async
      // _acquirePosition() hasn't completed yet, leaving the spinner visible.
      //
      // We use pump() rather than pumpAndSettle to avoid waiting indefinitely
      // for the unresolved Future (getPosition would time out or throw on a
      // test device that has no location stub).
      //
      // Because getPosition() will eventually throw (no permission in tests),
      // we wrap in an expectation that doesn't rely on it completing.
      await tester.pumpWidget(_buildPicker());
      // After the first pump the loading widget should be visible.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets(
        '"Set destination" button is disabled when no pin has been dropped',
        (tester) async {
      // Supply a position so the screen skips the GPS call and renders the map.
      await tester.pumpWidget(
        _buildPicker(initialPosition: const LatLng(51.5074, -0.1278)),
      );
      // Allow the widget tree to settle (tiles will time out, that's fine).
      await tester.pump(const Duration(milliseconds: 100));

      // The FilledButton labelled "Set destination" should exist but be disabled
      // (onPressed is null until a pin is placed).
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Set destination'),
      );
      expect(button.onPressed, isNull,
          reason: 'Button must be disabled until the user drops a pin');
    });

    testWidgets('shows AppBar with title "Pick a destination"', (tester) async {
      await tester.pumpWidget(
        _buildPicker(initialPosition: const LatLng(51.5074, -0.1278)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Pick a destination'), findsOneWidget);
    });

    testWidgets('shows hint text when no pin has been placed', (tester) async {
      await tester.pumpWidget(
        _buildPicker(initialPosition: const LatLng(51.5074, -0.1278)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.text('Tap the map to place a destination'),
        findsOneWidget,
      );
    });
  });
}
