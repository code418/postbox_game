// Widget tests for OfflineBanner (ROADMAP v1.5, offline play Phase 1/3).
//
// The banner mounts unconditionally in Home (beside MaintenanceBanner),
// renders nothing while online with an empty outbox, announces offline
// state, and surfaces banked captures with a manual "Send now" once the
// link is back.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/services/claim_outbox.dart';
import 'package:postbox_game/services/connectivity_service.dart';
import 'package:postbox_game/widgets/offline_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal RC stand-in: only the flags OfflineBanner reads.
class _StubRemoteConfig extends Fake implements FirebaseRemoteConfig {
  _StubRemoteConfig({this.offlineKilled = false});
  final bool offlineKilled;

  @override
  bool getBool(String key) =>
      key == RemoteConfigService.keyKillSwitchOfflineClaims
          ? offlineKilled
          : false;
}

void _useRemoteConfig({bool offlineKilled = false}) {
  RemoteConfigService.instance = RemoteConfigService(
      remoteConfig: _StubRemoteConfig(offlineKilled: offlineKilled));
}

Future<ConnectivityService> _connectivity(
    StreamController<List<ConnectivityResult>> updates,
    List<ConnectivityResult> initial) async {
  final service =
      ConnectivityService(check: () async => initial, changes: updates.stream);
  await service.init();
  return service;
}

OutboxEntry _entry(String id) => OutboxEntry(
      scanId: 'tok-$id',
      lat: 51.5,
      lng: -0.12,
      capturedWallMs: DateTime.now().millisecondsSinceEpoch,
      capturedMonotonicMs: 0,
      attemptId: id,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ClaimOutbox.resetForTest();
    ConnectivityService.resetForTest();
    _useRemoteConfig();
  });
  tearDown(RemoteConfigService.resetForTest);

  testWidgets('renders nothing while online with an empty outbox',
      (tester) async {
    final updates = StreamController<List<ConnectivityResult>>.broadcast();
    addTearDown(updates.close);
    ConnectivityService.instance =
        await _connectivity(updates, [ConnectivityResult.wifi]);

    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: OfflineBanner())));
    expect(find.byType(SizedBox), findsWidgets);
    expect(find.textContaining('offline'), findsNothing);
  });

  testWidgets('announces offline state, and pending captures when banked',
      (tester) async {
    final updates = StreamController<List<ConnectivityResult>>.broadcast();
    addTearDown(updates.close);
    ConnectivityService.instance =
        await _connectivity(updates, [ConnectivityResult.none]);

    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: OfflineBanner())));
    await tester.pump();
    expect(find.textContaining("offline"), findsOneWidget);

    await ClaimOutbox.instance.add(_entry('a1'));
    await tester.pump();
    expect(find.textContaining('1 claim'), findsOneWidget);
  });

  testWidgets('back online with banked captures: offers Send now',
      (tester) async {
    final updates = StreamController<List<ConnectivityResult>>.broadcast();
    addTearDown(updates.close);
    ConnectivityService.instance =
        await _connectivity(updates, [ConnectivityResult.wifi]);
    await ClaimOutbox.instance.add(_entry('a1'));
    await ClaimOutbox.instance.add(_entry('a2'));

    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: OfflineBanner())));
    await tester.pump();

    expect(find.textContaining('2 claims'), findsOneWidget);
    expect(find.text('Send now'), findsOneWidget);
  });

  testWidgets('kill switch: banked captures are held, Send now is withdrawn',
      (tester) async {
    _useRemoteConfig(offlineKilled: true);
    final updates = StreamController<List<ConnectivityResult>>.broadcast();
    addTearDown(updates.close);
    ConnectivityService.instance =
        await _connectivity(updates, [ConnectivityResult.wifi]);
    await ClaimOutbox.instance.add(_entry('a1'));

    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: OfflineBanner())));
    await tester.pump();

    expect(find.textContaining('held'), findsOneWidget);
    expect(find.text('Send now'), findsNothing,
        reason: 'the server would refuse the flush, so do not offer it');
  });

  testWidgets('kill switch: offline copy stops promising a later post',
      (tester) async {
    _useRemoteConfig(offlineKilled: true);
    final updates = StreamController<List<ConnectivityResult>>.broadcast();
    addTearDown(updates.close);
    ConnectivityService.instance =
        await _connectivity(updates, [ConnectivityResult.none]);

    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: OfflineBanner())));
    await tester.pump();

    expect(find.textContaining('offline'), findsOneWidget);
    expect(find.textContaining('saved to post later'), findsNothing);
  });
}
