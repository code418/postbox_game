// Tests for the History screen's map view, focused on the "My location"
// control added alongside the existing Refresh button.
//
// Notes on scope:
//  - The control is a `Positioned` IconButton overlaid in the widget tree (not
//    a FlutterMap canvas gesture), so unlike the destination picker's map taps
//    it IS reachable by `find.byTooltip` + `tester.tap`.
//  - Marker assertions read the `PostboxMap` widget's `markers` list rather
//    than hunting MarkerLayer's painted output, so they do not depend on tile
//    loading or viewport culling.
//  - `userClaimHistory` and `getPosition` are both injected; geolocator has no
//    MethodChannel mock in test/, so a real call throws MissingPluginException.

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/claim_history_screen.dart';
import 'package:postbox_game/location_service.dart';
import 'package:postbox_game/widgets/postbox_map.dart';


class _FakeResult<T> implements HttpsCallableResult<T> {
  _FakeResult(this.data);
  @override
  final T data;
}

Position _fakePos({double lat = 51.4, double lng = -0.2}) => Position(
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

/// Two claims, deliberately away from the fake fix so a camera move is
/// unambiguous.
Map<String, dynamic> _entry(String id, double lat, double lng) => {
      'postboxId': id,
      'lat': lat,
      'lng': lng,
      'monarch': 'EIIR',
      'timesClaimed': 1,
      'totalPoints': 2,
    };

Future<HttpsCallableResult<dynamic>> _twoEntries(Map<String, dynamic> _) async =>
    _FakeResult<dynamic>(<String, dynamic>{
      'entries': [
        _entry('a', 51.50, -0.10),
        _entry('b', 51.51, -0.11),
      ],
    });

/// Lets the injected callable/provider futures resolve. Never pumpAndSettle:
/// flutter_map's tile loads never settle in a headless test.
Future<void> _settle(WidgetTester tester) => tester
    .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)))
    .then((_) => tester.pump(const Duration(milliseconds: 100)));

Widget _app({
  ClaimHistoryCallableFn? callable,
  Future<Position> Function()? position,
}) =>
    MaterialApp(
      home: Scaffold(
        body: ClaimHistoryScreen(
          historyCallable: callable ?? _twoEntries,
          positionProvider: position ?? (() async => _fakePos()),
        ),
      ),
    );

PostboxMap _map(WidgetTester tester) =>
    tester.widget<PostboxMap>(find.byType(PostboxMap));

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    // flutter_map's tile cache calls getApplicationCacheDirectory, which has no
    // implementation headless. Stub it so the map can build.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => '.',
    );
  });

  testWidgets('coming back on a new London day refetches the history',
      (tester) async {
    // The tabs are kept alive all session; before this, "Today" kept showing
    // yesterday's claims the next morning until a claim or a manual refresh.
    var day = '2026-09-24';
    final periods = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ClaimHistoryScreen(
          historyCallable: (payload) {
            periods.add(payload['period'] as String);
            return _twoEntries(payload);
          },
          positionProvider: () async => _fakePos(),
          today: () => day,
        ),
      ),
    ));
    await _settle(tester);
    final initial = periods.length;
    expect(initial, greaterThan(0));

    // Same day: a resume changes nothing.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester);
    expect(periods.length, initial);

    // Next morning: every mounted tab refetches.
    day = '2026-09-25';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester);
    expect(periods.length, initial * 2);
  });

  testWidgets('map view shows the control and no dot before it is tapped',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(_app(position: () async {
      calls++;
      return _fakePos();
    }));
    await _settle(tester);

    expect(find.byType(PostboxMap), findsOneWidget);
    expect(find.byTooltip('My location'), findsOneWidget);
    expect(find.byTooltip('Refresh'), findsOneWidget);
    expect(_map(tester).markers, hasLength(2),
        reason: 'two claims, no user dot yet');
    expect(calls, 0, reason: 'GPS must not be read until the user asks');
  });

  testWidgets('tapping adds the user dot and moves the camera', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_app(position: () async {
      calls++;
      return _fakePos();
    }));
    await _settle(tester);

    await tester.tap(find.byTooltip('My location'));
    await _settle(tester);

    expect(calls, 1);
    final map = _map(tester);
    expect(map.markers, hasLength(3), reason: '2 claims + the user dot');
    // LatLng has value equality, so this is order-independent.
    expect(map.markers.map((m) => m.point), contains(const LatLng(51.4, -0.2)));

    final camera = map.mapController!.camera;
    expect(camera.center.latitude, closeTo(51.4, 1e-6));
    expect(camera.center.longitude, closeTo(-0.2, 1e-6));
    expect(camera.zoom, 16.0);
    expect(camera.zoom, lessThanOrEqualTo(17.0),
        reason: 'privacy cap: OSM shows postbox POI icons at zoom >= 18');
  });

  testWidgets('permanently-denied permission offers an Open Settings action',
      (tester) async {
    await tester.pumpWidget(_app(
      position: () async => throw const LocationServiceException(
          LocationErrorKind.permissionPermanentlyDenied,
          'Location permission permanently denied.'),
    ));
    await _settle(tester);

    await tester.tap(find.byTooltip('My location'));
    await _settle(tester);

    expect(find.text('Location permission permanently denied.'), findsOneWidget);
    expect(find.widgetWithText(SnackBarAction, 'Open Settings'), findsOneWidget);
    expect(_map(tester).markers, hasLength(2), reason: 'no dot on failure');
  });

  testWidgets('plain denial shows the message with no settings action',
      (tester) async {
    await tester.pumpWidget(_app(
      position: () async => throw const LocationServiceException(
          LocationErrorKind.permissionDenied, 'Location permission denied.'),
    ));
    await _settle(tester);

    await tester.tap(find.byTooltip('My location'));
    await _settle(tester);

    expect(find.text('Location permission denied.'), findsOneWidget);
    expect(find.byType(SnackBarAction), findsNothing);
    // The finally clause must have re-enabled the button.
    final button = tester.widget<IconButton>(
        find.ancestor(of: find.byIcon(Icons.my_location),
            matching: find.byType(IconButton)));
    expect(button.onPressed, isNotNull);
  });

  testWidgets('an unexpected failure does not leak a raw exception string',
      (tester) async {
    await tester.pumpWidget(
        _app(position: () async => throw StateError('boom')));
    await _settle(tester);

    await tester.tap(find.byTooltip('My location'));
    await _settle(tester);

    expect(find.text('Could not determine your location. Please try again.'),
        findsOneWidget);
    expect(find.textContaining('boom'), findsNothing);
  });

  testWidgets('the user dot survives a refresh', (tester) async {
    // Regression test: the map lives inside a FutureBuilder that flips back to
    // `waiting` when _future is replaced, which UNMOUNTS _HistoryMap. Position
    // state therefore has to live on the screen, not inside the map.
    await tester.pumpWidget(_app());
    await _settle(tester);

    await tester.tap(find.byTooltip('My location'));
    await _settle(tester);
    expect(_map(tester).markers, hasLength(3));

    await tester.tap(find.byTooltip('Refresh'));
    await tester.pump();
    // Proof of the unmount this test guards against: mid-refetch the map is
    // gone entirely, replaced by the FutureBuilder's waiting spinner.
    expect(find.byType(PostboxMap), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await _settle(tester);

    expect(_map(tester).markers, hasLength(3),
        reason: 'the dot must not vanish when the claim list refetches');
  });
}
