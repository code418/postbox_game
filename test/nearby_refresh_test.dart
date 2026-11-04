// A failed Nearby REFRESH must leave the player's last good results on screen.
// Every error path used to reset to the pre-scan screen, so a signal blip
// during a pull-to-refresh threw away a perfectly good result set.

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:postbox_game/nearby.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/widgets/claim_quiz_sheet.dart'
    show NearbyPostboxesCallableFn;
import 'package:shared_preferences/shared_preferences.dart';

class _FakeResult<T> implements HttpsCallableResult<T> {
  _FakeResult(this.data);
  @override
  final T data;
}

class _FakeFunctionsException extends FirebaseFunctionsException {
  _FakeFunctionsException({required super.code, required super.message});
}

class _StubRemoteConfig extends Fake implements FirebaseRemoteConfig {
  @override
  bool getBool(String key) => false;
  @override
  String getString(String key) => '';
  @override
  double getDouble(String key) => 0.0;
  @override
  int getInt(String key) => 0;
}

Position _pos() => Position(
      latitude: 51.5,
      longitude: -0.12,
      timestamp: DateTime.now(),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

/// Succeeds with three EIIR boxes, then fails every later call with a
/// non-retryable code (so retryOnUnavailable doesn't back off in the test).
NearbyPostboxesCallableFn _okThenFail() {
  var calls = 0;
  return (_) async {
    if (calls++ > 0) {
      throw _FakeFunctionsException(code: 'internal', message: 'boom');
    }
    return _FakeResult<dynamic>(<String, dynamic>{
      'counts': {'total': 3, 'claimedToday': 0, 'EIIR': 3},
      'points': {'min': 2, 'max': 2},
      'compass': {'N': 3},
      'claimedCompass': <String, dynamic>{},
    });
  };
}

/// The pre-scan screen's "Find nearby postboxes" button (the label text
/// also appears as the heading).
final _scanButton = find.byIcon(Icons.search);

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    SharedPreferences.setMockInitialValues({});
    // The results render maps; flutter_map's tile cache asks path_provider.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => '.',
    );
    // An open, silent compass stream (see wear_shell_paging_test.dart).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      const EventChannel('hemanthraj/flutter_compass'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
  });

  setUp(() {
    RemoteConfigService.instance =
        RemoteConfigService(remoteConfig: _StubRemoteConfig());
  });
  tearDown(RemoteConfigService.resetForTest);

  Future<void> pumpNearby(WidgetTester tester) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Nearby(
              nearbyCallable: _okThenFail(),
              positionProvider: () async => _pos(),
            ),
          ),
        ),
      );

  testWidgets('a failed refresh keeps the last results on screen',
      (tester) async {
    await pumpNearby(tester);
    await tester.tap(_scanButton);
    await _settle(tester);
    expect(find.text('3 postboxes nearby'), findsOneWidget);

    await tester.ensureVisible(find.text('Refresh'));
    await tester.tap(find.text('Refresh'));
    await _settle(tester);

    expect(find.text('3 postboxes nearby'), findsOneWidget,
        reason: 'the previous result set survives the failed refresh');
    expect(_scanButton, findsNothing);
    expect(find.text('Could not fetch postboxes. Please try again.'),
        findsOneWidget);
  });

  testWidgets('a failed first scan still returns to the pre-scan screen',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Nearby(
          nearbyCallable: (_) async =>
              throw _FakeFunctionsException(code: 'internal', message: 'x'),
          positionProvider: () async => _pos(),
        ),
      ),
    ));
    await tester.tap(_scanButton);
    await _settle(tester);
    expect(_scanButton, findsOneWidget);
  });
}
