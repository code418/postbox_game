// Home keeps its tabs alive in an IndexedStack, so Claim and Nearby sit
// mounted behind Settings while the player changes their distance unit. They
// used to read the unit only on start and on each scan, so after choosing
// miles the Claim tab still said "Stand within 30 m" until the next scan.

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/app_preferences.dart';
import 'package:postbox_game/claim.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// No remote overrides: the claim radius falls back to its 30 m default.
class _StubRemoteConfig extends Fake implements FirebaseRemoteConfig {
  @override
  bool getBool(String key) => false;
  @override
  double getDouble(String key) => 0;
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppPreferences.distanceUnitChanged.value = null;
    RemoteConfigService.instance =
        RemoteConfigService(remoteConfig: _StubRemoteConfig());
  });
  tearDown(RemoteConfigService.resetForTest);

  test('setDistanceUnit announces the new unit', () async {
    final seen = <DistanceUnit?>[];
    void listener() => seen.add(AppPreferences.distanceUnitChanged.value);
    AppPreferences.distanceUnitChanged.addListener(listener);
    addTearDown(
        () => AppPreferences.distanceUnitChanged.removeListener(listener));

    await AppPreferences.setDistanceUnit(DistanceUnit.miles);
    expect(seen, [DistanceUnit.miles]);
    expect(await AppPreferences.getDistanceUnit(), DistanceUnit.miles);
  });

  testWidgets('the mounted Claim tab follows a unit change without a scan',
      (tester) async {
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Claim())));
    await tester.pump();
    expect(find.textContaining('Stand within 30 m'), findsOneWidget);

    await tester.runAsync(
        () => AppPreferences.setDistanceUnit(DistanceUnit.miles));
    await tester.pump();

    expect(find.textContaining('Stand within 33 yd'), findsOneWidget);
    expect(find.textContaining('30 m'), findsNothing);
  });
}
