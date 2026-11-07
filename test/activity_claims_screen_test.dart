import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/activity/activity_claims_screen.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/services/activity_claims_service.dart';
import 'package:postbox_game/services/activity_store.dart';
import 'package:postbox_game/services/health_connect_bridge.dart';
import 'package:postbox_game/widgets/activity_candidates_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/activity_fakes.dart';

void main() {
  late FakeHealthConnectBridge bridge;
  late ActivityStore store;
  late int matchCalls;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RemoteConfigService.instance = RemoteConfigService(remoteConfig: FakeActivityRemoteConfig());
    bridge = FakeHealthConnectBridge();
    store = ActivityStore();
    matchCalls = 0;
  });
  tearDown(RemoteConfigService.resetForTest);

  final now = DateTime.now().millisecondsSinceEpoch;
  final run = HcSession(
    id: 's1',
    type: 'running',
    startMs: now - 2 * 3600000,
    endMs: now - 3600000,
    lastModifiedMs: 1,
    originPackage: 'com.fitbit.FitbitMobile',
    recordingMethod: 'active',
  );

  ActivityClaimsService service() => ActivityClaimsService(
        bridge: bridge,
        store: store,
        matchCallable: (_) async {
          matchCalls++;
          return FakeCallableResult<dynamic>({
            'ok': true,
            'candidates': [candidateDto('k1', now - 90 * 60000)],
            'alreadyClaimed': 1,
          });
        },
        claimCallable: (_) async => FakeCallableResult<dynamic>(<String, Object>{}),
        uidProvider: () => 'u1',
        remoteConfig: () => RemoteConfigService.instance,
        isOnline: () => true,
        deviceIdProvider: () async => null,
      );

  Future<void> pumpScreen(WidgetTester tester, ActivityClaimsService svc) async {
    await tester.pumpWidget(MaterialApp(home: ActivityClaimsScreen(service: svc)));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  testWidgets('explains when the device cannot do workout claims', (tester) async {
    bridge.supported = false;
    await pumpScreen(tester, service());
    expect(find.textContaining("aren't available on this device"), findsOneWidget);
  });

  testWidgets('offers to install Health Connect when it is missing', (tester) async {
    bridge.avail = HcAvailability.notInstalled;
    await pumpScreen(tester, service());
    expect(find.text('Get Health Connect'), findsOneWidget);
  });

  testWidgets('shows the disclosure before connecting, then checks and lists candidates', (tester) async {
    bridge.granted = {};
    bridge.sessions = [run];
    bridge.routes['s1'] = HcRouteData(eastTrack(run.startMs));
    await pumpScreen(tester, service());
    expect(find.text('What we read, and why'), findsOneWidget);
    expect(find.textContaining('never stored'), findsOneWidget);
    expect(bridge.readSessionsCalls, 0, reason: 'nothing is read before the player connects');

    await tester.scrollUntilVisible(find.text('Connect Health Connect'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Connect Health Connect'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(bridge.permissionRequests, 1);
    expect(matchCalls, 1);
    expect(find.text('Ready to claim'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Claim'), findsOneWidget);
    expect(find.textContaining('1 to claim · 1 already claimed'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10)); // let James' strip settle
  });

  testWidgets('a run that needs route access offers a Check button', (tester) async {
    await store.setOptedIn('u1', true);
    bridge.granted = {HealthConnectPermissions.readExercise};
    bridge.sessions = [run];
    bridge.routes['s1'] = const HcRouteConsentRequired();
    await pumpScreen(tester, service());
    expect(find.text('Allow route access for every workout'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Check'), findsOneWidget);
    expect(bridge.consentRequests, isEmpty);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Check'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(bridge.consentRequests, ['s1']);
    await tester.pump(const Duration(seconds: 10));
  });

  group('ActivityCandidatesBanner', () {
    testWidgets('is invisible with nothing waiting and counts candidates otherwise', (tester) async {
      final svc = service();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ActivityCandidatesBanner(service: svc))));
      expect(find.textContaining('unclaimed'), findsNothing);
      svc.bannerCount.value = 2;
      await tester.pump();
      expect(find.text('2 unclaimed postboxes on your recent workouts'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(svc.bannerCount.value, 0);
    });
  });
}
