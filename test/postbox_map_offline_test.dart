// Widget tests for PostboxMap's offline tile gating (ROADMAP v1.5).
//
// Offline, live OSM tile fetches can only fail — the map card used to render
// as a dead grey rectangle (the Airplane Mode symptom on the claim sheet's
// radius map). PostboxMap now drops its TileLayer while
// ConnectivityService reports offline, keeps the geometry overlays (radius
// circles, markers) legible on a flat themed background, shows an
// "Offline — map unavailable" hint, and restores tiles when the link returns.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/services/connectivity_service.dart';
import 'package:postbox_game/widgets/postbox_map.dart';

const _center = LatLng(51.5, -0.12);

Future<ConnectivityService> _connectivity(
    StreamController<List<ConnectivityResult>> updates,
    List<ConnectivityResult> initial) async {
  final service =
      ConnectivityService(check: () async => initial, changes: updates.stream);
  await service.init();
  return service;
}

Widget _host() => MaterialApp(
      home: Scaffold(
        body: PostboxMap(
          center: _center,
          circleMarkers: [scanRadiusCircle(_center, radiusMeters: 30)],
          markers: [
            Marker(point: _center, child: const Icon(Icons.person_pin_circle)),
          ],
        ),
      ),
    );

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // flutter_map's built-in tile cache calls getApplicationCacheDirectory on
    // path_provider, which has no implementation in the headless test. Same
    // stub as claim_quiz_sheet_test.dart.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => '.',
    );
  });

  setUp(ConnectivityService.resetForTest);

  testWidgets('online: renders live tiles and no offline hint',
      (tester) async {
    final updates = StreamController<List<ConnectivityResult>>.broadcast();
    addTearDown(updates.close);
    ConnectivityService.instance =
        await _connectivity(updates, [ConnectivityResult.wifi]);

    await tester.pumpWidget(_host());
    await tester.pump();

    expect(find.byType(TileLayer), findsOneWidget);
    expect(find.textContaining('Offline'), findsNothing);
  });

  testWidgets('offline: drops the tile layer, keeps geometry, shows the hint',
      (tester) async {
    final updates = StreamController<List<ConnectivityResult>>.broadcast();
    addTearDown(updates.close);
    ConnectivityService.instance =
        await _connectivity(updates, [ConnectivityResult.none]);

    await tester.pumpWidget(_host());
    await tester.pump();

    expect(find.byType(TileLayer), findsNothing,
        reason: 'live tile fetches cannot succeed offline');
    expect(find.text('Offline — map unavailable'), findsOneWidget);
    expect(find.byType(CircleLayer), findsOneWidget,
        reason: 'the claim-radius circle must survive without tiles');
    expect(find.byType(MarkerLayer), findsOneWidget,
        reason: 'the user-position marker must survive without tiles');
  });

  testWidgets('tiles restore automatically when connectivity returns',
      (tester) async {
    final updates = StreamController<List<ConnectivityResult>>.broadcast();
    addTearDown(updates.close);
    ConnectivityService.instance =
        await _connectivity(updates, [ConnectivityResult.none]);

    await tester.pumpWidget(_host());
    await tester.pump();
    expect(find.byType(TileLayer), findsNothing);

    updates.add([ConnectivityResult.wifi]);
    await tester.pump();
    await tester.pump();

    expect(find.byType(TileLayer), findsOneWidget);
    expect(find.textContaining('Offline'), findsNothing);
  });
}
