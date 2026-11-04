// Drives the Wear claim page's scan → claim state machine through its test
// seams (the phone's ClaimQuizSheet has the equivalent coverage).

import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/wear/wear_claim_page.dart';
import 'package:postbox_game/wear/wear_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeResult<T> implements HttpsCallableResult<T> {
  _FakeResult(this.data);
  @override
  final T data;
}

/// Maintenance off, no remote overrides.
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

/// One unclaimed box with no recognised cipher, so "Claim!" claims directly
/// (no quiz to answer).
Future<HttpsCallableResult<dynamic>> _oneBox(Map<String, dynamic> _) async =>
    _FakeResult<dynamic>(<String, dynamic>{
      'counts': {'total': 1, 'claimedToday': 0},
      'points': {'min': 2, 'max': 2},
      'postboxes': {
        'pb1': {'distance': 12.0, 'claimedToday': false, 'monarch': 'UNKNOWN'},
      },
      'compass': <String, dynamic>{},
      'claimedCompass': <String, dynamic>{},
    });

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RemoteConfigService.instance =
        RemoteConfigService(remoteConfig: _StubRemoteConfig());
  });
  tearDown(RemoteConfigService.resetForTest);

  testWidgets('a double-tap on Claim! claims once and keeps the success',
      (tester) async {
    // Both taps land before the next frame removes the button. Without the
    // re-entry guard a second startScoring ran; only one can score, and when
    // the loser's "already claimed" answer arrived second it replaced the
    // "Claimed!" screen with a rescan.
    var claims = 0;
    // Holds the first claim in flight, as a real round trip would.
    final firstClaim = Completer<void>();
    await tester.pumpWidget(MaterialApp(
      theme: WearTheme.dark,
      home: Scaffold(
        body: WearClaimPage(
          signedIn: true,
          nearbyCallable: _oneBox,
          positionProvider: () async => _pos(),
          claimCallable: (_) async {
            final n = ++claims;
            if (n == 1) await firstClaim.future;
            return _FakeResult<dynamic>(n == 1
                ? {'found': true, 'claimed': 1, 'points': 2,
                   'allClaimedToday': false}
                : {'found': true, 'claimed': 0, 'points': 0,
                   'allClaimedToday': true});
          },
        ),
      ),
    ));

    await tester.tap(find.text('Scan & Claim'));
    await _settle(tester);
    expect(find.text('Claim!'), findsOneWidget);

    await tester.tap(find.text('Claim!'));
    await tester.tap(find.text('Claim!')); // same frame: button still there
    await _settle(tester);
    firstClaim.complete();
    await _settle(tester);
    await _settle(tester);

    expect(claims, 1);
    expect(find.text('Claimed!'), findsOneWidget);
  });
}
