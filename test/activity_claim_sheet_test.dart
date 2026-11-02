import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/activity/activity_claim_sheet.dart';
import 'package:postbox_game/activity/activity_helpers.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/services/activity_claims_service.dart';
import 'package:postbox_game/services/activity_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/activity_fakes.dart';

void main() {
  late FakeActivityRemoteConfig rc;
  late List<Map<String, dynamic>> claimCalls;
  late Future<Object?> Function(Map<String, dynamic>) claimImpl;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    rc = FakeActivityRemoteConfig();
    RemoteConfigService.instance = RemoteConfigService(remoteConfig: rc);
    claimCalls = [];
    claimImpl = (_) async => {'found': true, 'claimed': 1, 'points': 7, 'allClaimedToday': false};
  });
  tearDown(RemoteConfigService.resetForTest);

  ActivityClaimsService service() => ActivityClaimsService(
        bridge: FakeHealthConnectBridge(),
        store: ActivityStore(),
        matchCallable: (_) async => FakeCallableResult<dynamic>(<String, Object>{}),
        claimCallable: (d) async {
          claimCalls.add(d);
          return FakeCallableResult<dynamic>(await claimImpl(d));
        },
        uidProvider: () => 'u1',
        remoteConfig: () => RemoteConfigService.instance,
        isOnline: () => true,
        deviceIdProvider: () async => null,
      );

  ActivityCandidate candidate({String? monarch = 'VR'}) => ActivityCandidate(
        token: 'tok',
        key: 'k1',
        passedAtMs: DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
        claimDate: '2026-11-02',
        boxes: [CandidateBox(monarch: monarch, points: 7)],
        sessionId: 's1',
        exerciseType: 'running',
        originPackage: 'com.fitbit.FitbitMobile',
      );

  Future<void> pumpSheet(WidgetTester tester, ActivityCandidate c, ActivityClaimsService svc) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ActivityClaimSheet(candidate: c, service: svc, afterClaim: () async {}),
      ),
    ));
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 2));
    }
  }

  testWidgets('offers the cypher that was on the box among the options', (tester) async {
    await pumpSheet(tester, candidate(), service());
    expect(find.textContaining('You passed this postbox'), findsOneWidget);
    expect(find.text('VR'), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNWidgets(4));
  });

  testWidgets('a wrong answer does not claim and can be retried', (tester) async {
    await pumpSheet(tester, candidate(), service());
    final wrong = find.descendant(of: find.byType(OutlinedButton), matching: find.byType(Text))
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .firstWhere((t) => t != null && t != 'VR' && t.length <= 15 && !t.contains(' '))!;
    await tester.tap(find.text(wrong));
    await tester.pump();
    expect(find.textContaining('Not quite'), findsOneWidget);
    expect(claimCalls, isEmpty);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(find.text('VR'), findsOneWidget);
  });

  testWidgets('the right answer claims with the token and an attemptId', (tester) async {
    await pumpSheet(tester, candidate(), service());
    await tester.tap(find.text('VR'));
    await settle(tester);
    expect(claimCalls, hasLength(1));
    expect(claimCalls.single['token'], 'tok');
    expect(claimCalls.single['attemptId'], isA<String>());
    expect(find.text('Claimed! +7 points'), findsOneWidget);
  });

  testWidgets('Retry after a transport failure reuses the same attemptId', (tester) async {
    claimImpl = (_) async => throw FakeFunctionsException('unavailable');
    await pumpSheet(tester, candidate(), service());
    await tester.tap(find.text('VR'));
    await settle(tester);
    expect(find.text('Retry'), findsOneWidget);
    claimImpl = (_) async => {'found': true, 'claimed': 1, 'points': 7, 'allClaimedToday': false};
    await tester.tap(find.text('Retry'));
    await settle(tester);
    expect(find.text('Claimed! +7 points'), findsOneWidget);
    final ids = claimCalls.map((c) => c['attemptId']).toSet();
    expect(ids, hasLength(1), reason: 'the server must be able to replay the first attempt');
  });

  testWidgets('a box with no known cypher claims without a quiz', (tester) async {
    await pumpSheet(tester, candidate(monarch: null), service());
    expect(find.text('Claim it'), findsOneWidget);
    await tester.tap(find.text('Claim it'));
    await settle(tester);
    expect(claimCalls, hasLength(1));
  });

  testWidgets('maintenance mode blocks the claim', (tester) async {
    rc.maintenance = true;
    await pumpSheet(tester, candidate(), service());
    await tester.tap(find.text('VR'));
    await settle(tester);
    expect(claimCalls, isEmpty);
  });

  testWidgets('an expired pass explains itself', (tester) async {
    claimImpl = (_) async => throw FakeFunctionsException('failed-precondition', details: {'reason': 'expired'});
    await pumpSheet(tester, candidate(), service());
    await tester.tap(find.text('VR'));
    await settle(tester);
    expect(find.text('That pass is too long ago to claim now.'), findsOneWidget);
  });
}
