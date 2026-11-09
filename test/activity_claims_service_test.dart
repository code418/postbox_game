import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/activity/activity_helpers.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/services/activity_claims_service.dart';
import 'package:postbox_game/services/activity_store.dart';
import 'package:postbox_game/services/health_connect_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/activity_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeHealthConnectBridge bridge;
  late FakeActivityRemoteConfig rc;
  late ActivityStore store;
  late List<Map<String, dynamic>> matchCalls;
  late List<Map<String, dynamic>> claimCalls;
  late Future<Object?> Function(Map<String, dynamic>) matchImpl;
  late Future<Object?> Function(Map<String, dynamic>) claimImpl;
  String? uid;
  late int now;
  late bool online;

  final t0 = DateTime(2026, 11, 2, 7).millisecondsSinceEpoch;

  HcSession run(String id, {int lastModified = 1, String origin = 'com.fitbit.FitbitMobile', String rm = 'active'}) =>
      HcSession(
        id: id,
        type: 'running',
        startMs: t0,
        endMs: t0 + 30 * 60000,
        lastModifiedMs: lastModified,
        originPackage: origin,
        recordingMethod: rm,
      );

  ActivityClaimsService makeService() => ActivityClaimsService(
        bridge: bridge,
        store: store,
        matchCallable: (d) async {
          matchCalls.add(d);
          return FakeCallableResult<dynamic>(await matchImpl(d));
        },
        claimCallable: (d) async {
          claimCalls.add(d);
          return FakeCallableResult<dynamic>(await claimImpl(d));
        },
        uidProvider: () => uid,
        clock: () => now,
        remoteConfig: () => RemoteConfigService(remoteConfig: rc),
        isOnline: () => online,
        deviceIdProvider: () async => null,
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    bridge = FakeHealthConnectBridge();
    rc = FakeActivityRemoteConfig();
    store = ActivityStore();
    matchCalls = [];
    claimCalls = [];
    uid = 'u1';
    now = t0 + 2 * 3600000;
    online = true;
    matchImpl = (d) async => {
          'ok': true,
          'candidates': [candidateDto('k1', t0 + 600000)],
          'alreadyClaimed': 0,
          'expiredPasses': 0,
          'truncated': false,
        };
    claimImpl = (d) async => {'found': true, 'claimed': 1, 'points': 7, 'allClaimedToday': false};
  });

  group('autoCheck', () {
    test('reads nothing until this account opts in', () async {
      bridge.sessions = [run('s1')];
      bridge.routes['s1'] = HcRouteData(eastTrack(t0));
      final svc = makeService();
      expect(await svc.autoCheck(), isNull);
      expect(bridge.readSessionsCalls, 0);
      expect(bridge.readRouteCalls, 0);
    });

    test('a device-level grant made by another account does not opt this one in', () async {
      await store.setOptedIn('u1', true);
      uid = 'u2';
      bridge.sessions = [run('s1')];
      expect(await makeService().autoCheck(), isNull);
      expect(bridge.readSessionsCalls, 0);
    });

    test('opted in: reads, matches once, stores and counts the candidate', () async {
      await store.setOptedIn('u1', true);
      bridge.sessions = [run('s1')];
      bridge.routes['s1'] = HcRouteData(eastTrack(t0));
      final svc = makeService();
      final summary = await svc.autoCheck();
      expect(summary, isNotNull);
      expect(summary!.newCandidates, 1);
      expect(matchCalls, hasLength(1));
      expect((matchCalls.single['session'] as Map)['id'], 's1');
      expect(svc.bannerCount.value, 1);
      final state = await svc.loadState();
      expect(state.candidates.single.key, 'k1');
      expect(state.candidates.single.sessionId, 's1');

      // Debounced straight after.
      expect(await svc.autoCheck(), isNull);
      // After the debounce the same session version is not re-sent.
      now += 21 * 60000;
      final again = await svc.autoCheck();
      expect(again!.newCandidates, 0);
      expect(matchCalls, hasLength(1));
    });

    test('never prompts for route access; announces a consent-needed run once', () async {
      await store.setOptedIn('u1', true);
      bridge.sessions = [run('s1')];
      bridge.routes['s1'] = const HcRouteConsentRequired();
      final svc = makeService();
      final first = await svc.autoCheck();
      expect(first!.consentNeeded, 1);
      expect(bridge.consentRequests, isEmpty);
      expect(matchCalls, isEmpty);
      now += 21 * 60000;
      final second = await svc.autoCheck();
      expect(second!.consentNeeded, 0, reason: 'already announced');
      expect(bridge.consentRequests, isEmpty);
    });

    test('skips when offline, in maintenance, flag off, or on an unsupported platform', () async {
      await store.setOptedIn('u1', true);
      bridge.sessions = [run('s1')];
      online = false;
      expect(await makeService().autoCheck(), isNull);
      online = true;
      rc.maintenance = true;
      expect(await makeService().autoCheck(), isNull);
      rc.maintenance = false;
      rc.enabled = false;
      expect(await makeService().autoCheck(), isNull);
      rc.enabled = true;
      rc.killed = true;
      expect(await makeService().autoCheck(), isNull);
      rc.killed = false;
      bridge.supported = false;
      expect(await makeService().autoCheck(), isNull);
      expect(bridge.readSessionsCalls, 0);
    });

    test('a spent daily budget is not cached as a verdict', () async {
      await store.setOptedIn('u1', true);
      bridge.sessions = [run('s1')];
      bridge.routes['s1'] = HcRouteData(eastTrack(t0));
      matchImpl = (_) async => throw FakeFunctionsException('resource-exhausted',
          details: {'reason': 'quota_exceeded'});
      final svc = makeService();
      final s = await svc.autoCheck();
      expect(s!.error, 'quota_exceeded');
      expect((await svc.loadState()).processedKeys, isEmpty);
    });

    test('a permanent server verdict is cached and never re-sent', () async {
      await store.setOptedIn('u1', true);
      bridge.sessions = [run('s1')];
      bridge.routes['s1'] = HcRouteData(eastTrack(t0));
      matchImpl = (_) async => {'ok': false, 'reason': 'origin_not_supported'};
      final svc = makeService();
      await svc.autoCheck();
      now += 21 * 60000;
      await svc.autoCheck();
      expect(matchCalls, hasLength(1));
      expect((await svc.loadState()).sessions.values.single.verdict, 'origin_not_supported');
    });
  });

  group('checkWithConsent', () {
    test('asks Health Connect for this run, then matches the granted route', () async {
      await store.setOptedIn('u1', true);
      final s = run('s1');
      bridge.consentRoutes['s1'] = HcRouteData(eastTrack(t0));
      final summary = await makeService().checkWithConsent(s);
      expect(bridge.consentRequests, ['s1']);
      expect(summary.newCandidates, 1);
      expect(matchCalls, hasLength(1));
    });

    test('in maintenance it neither prompts nor matches', () async {
      await store.setOptedIn('u1', true);
      rc.maintenance = true;
      final summary = await makeService().checkWithConsent(run('s1'));
      expect(summary.error, 'maintenance');
      expect(bridge.consentRequests, isEmpty);
      expect(matchCalls, isEmpty);
    });

    test('a declined prompt is recorded but not final', () async {
      await store.setOptedIn('u1', true);
      final svc = makeService();
      await svc.checkWithConsent(run('s1'));
      final state = await svc.loadState();
      expect(state.sessions.values.single.verdict, 'denied');
      expect(state.processedKeys, isEmpty);
    });
  });

  group('claim', () {
    Future<ActivityCandidate> seed(ActivityClaimsService svc) async {
      await store.setOptedIn('u1', true);
      bridge.sessions = [run('s1')];
      bridge.routes['s1'] = HcRouteData(eastTrack(t0));
      await svc.autoCheck();
      return (await svc.loadState()).candidates.single;
    }

    test('sends the token and attemptId and settles the candidate', () async {
      final svc = makeService();
      final c = await seed(svc);
      final o = await svc.claim(c, attemptId: 'a1');
      expect(o.kind, ActivityClaimKind.claimed);
      expect(o.points, 7);
      expect(claimCalls.single['token'], 'token-k1');
      expect(claimCalls.single['attemptId'], 'a1');
      expect(claimCalls.single['clientTsMs'], now);
      expect(svc.bannerCount.value, 0);
      expect((await svc.loadState()).claimed.keys, ['k1']);
    });

    test('maps a transport failure to transport and keeps the candidate', () async {
      final svc = makeService();
      final c = await seed(svc);
      claimImpl = (_) async => throw FakeFunctionsException('unavailable');
      final o = await svc.claim(c, attemptId: 'a1');
      expect(o.kind, ActivityClaimKind.transport);
      expect(claimCalls.length, greaterThan(1), reason: 'auto-retried with the same id');
      expect(claimCalls.every((d) => d['attemptId'] == 'a1'), isTrue);
      expect(svc.bannerCount.value, 1);
    });

    test('maps server reasons and dismisses dead candidates', () async {
      final svc = makeService();
      final c = await seed(svc);
      claimImpl = (_) async => throw FakeFunctionsException('failed-precondition', details: {'reason': 'expired'});
      expect((await svc.claim(c, attemptId: 'a2')).kind, ActivityClaimKind.expired);
      expect((await svc.loadState()).dismissed.keys, ['k1']);
    });

    test('maps quota, already-claimed and not-found', () async {
      final svc = makeService();
      final c = await seed(svc);
      claimImpl = (_) async => throw FakeFunctionsException('resource-exhausted');
      expect((await svc.claim(c, attemptId: 'a')).kind, ActivityClaimKind.quotaExceeded);
      claimImpl = (_) async => {'found': true, 'claimed': 0, 'points': 0, 'allClaimedToday': true};
      expect((await svc.claim(c, attemptId: 'b')).kind, ActivityClaimKind.alreadyClaimed);
      claimImpl = (_) async => {'found': false, 'claimed': 0, 'points': 0, 'allClaimedToday': false};
      expect((await svc.claim(c, attemptId: 'c')).kind, ActivityClaimKind.notFound);
    });
  });

  test('switching account hides the previous player\'s candidates', () async {
    await store.setOptedIn('u1', true);
    bridge.sessions = [run('s1')];
    bridge.routes['s1'] = HcRouteData(eastTrack(t0));
    final svc = makeService();
    await svc.autoCheck();
    expect((await svc.loadState()).candidates, hasLength(1));
    uid = 'u2';
    expect((await svc.loadState()).candidates, isEmpty);
    await svc.refreshBanner();
    expect(svc.bannerCount.value, 0);
  });

  test('connect opts in only when sessions are granted; disconnect revokes and forgets', () async {
    final svc = makeService();
    bridge.grantOnRequest = {};
    expect(await svc.connect(), isEmpty);
    expect(await svc.optedIn(), isFalse);
    bridge.grantOnRequest = {HealthConnectPermissions.readExercise};
    await svc.connect();
    expect(await svc.optedIn(), isTrue);
    await svc.disconnect();
    expect(bridge.revoked, isTrue);
    expect(await svc.optedIn(), isFalse);
  });

  test('snoozeBanner hides current candidates from the banner only', () async {
    await store.setOptedIn('u1', true);
    bridge.sessions = [run('s1')];
    bridge.routes['s1'] = HcRouteData(eastTrack(t0));
    final svc = makeService();
    await svc.autoCheck();
    await svc.snoozeBanner();
    expect(svc.bannerCount.value, 0);
    expect((await svc.loadState()).claimable(now, svc.graceMs), hasLength(1));
  });

  group('concurrency', () {
    // Turns the event loop until [cond] holds (bounded), so a test can hold a
    // matchActivityRoute call open and act while it is in flight.
    Future<void> until(bool Function() cond) async {
      for (var i = 0; i < 1000 && !cond(); i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(cond(), isTrue, reason: 'condition never held');
    }

    Map<String, Object> matched(String key) => {
          'ok': true,
          'candidates': [candidateDto(key, t0 + 900000)],
          'alreadyClaimed': 0,
          'expiredPasses': 0,
          'truncated': false,
        };

    test('a claim made while a check is in flight survives the check', () async {
      await store.setOptedIn('u1', true);
      bridge.sessions = [run('s1')];
      bridge.routes['s1'] = HcRouteData(eastTrack(t0));
      final svc = makeService();
      await svc.autoCheck();
      final c = (await svc.loadState()).candidates.single;

      // A second run syncs; its match is held open while the player claims k1.
      bridge.sessions = [run('s1'), run('s2')];
      bridge.routes['s2'] = HcRouteData(eastTrack(t0));
      final gate = Completer<Object?>();
      matchImpl = (_) => gate.future;
      final check = svc.refresh();
      await until(() => matchCalls.length == 2);

      expect((await svc.claim(c, attemptId: 'a1')).kind, ActivityClaimKind.claimed);
      gate.complete(matched('k2'));
      expect((await check).newCandidates, 1);

      final state = await svc.loadState();
      expect(state.claimed.keys, ['k1'], reason: "the check's save must not undo the claim");
      expect(state.claimable(now, svc.graceMs).map((x) => x.key), ['k2']);
      expect(svc.bannerCount.value, 1);
    });

    test('overlapping resume checks run once', () async {
      await store.setOptedIn('u1', true);
      bridge.sessions = [run('s1')];
      bridge.routes['s1'] = HcRouteData(eastTrack(t0));
      final svc = makeService();
      final results = await Future.wait([svc.autoCheck(), svc.autoCheck()]);
      expect(results.whereType<ActivityCheckSummary>(), hasLength(1));
      expect(bridge.readSessionsCalls, 1);
      expect(matchCalls, hasLength(1));
    });

    test('disconnecting mid-check does not bring the forgotten state back', () async {
      await store.setOptedIn('u1', true);
      bridge.sessions = [run('s1')];
      bridge.routes['s1'] = HcRouteData(eastTrack(t0));
      final gate = Completer<Object?>();
      matchImpl = (_) => gate.future;
      final svc = makeService();
      final check = svc.refresh();
      await until(() => matchCalls.isNotEmpty);

      await svc.disconnect();
      gate.complete(matched('k1'));
      await check;

      final state = await svc.loadState();
      expect(state.candidates, isEmpty);
      expect(state.sessions, isEmpty);
      expect(svc.bannerCount.value, 0);
    });
  });

  group('MethodChannelHealthConnectBridge', () {
    test('a missing plugin (wear, iOS, tests) reads as unsupported', () async {
      final b = MethodChannelHealthConnectBridge(
        channel: const MethodChannel('test/no_handler_health_connect'),
        isSupportedPlatform: () => true,
      );
      expect(await b.availability(), HcAvailability.unsupported);
      expect(await b.grantedPermissions(), isEmpty);
    });

    test('off Android it never touches the channel', () async {
      final b = MethodChannelHealthConnectBridge(isSupportedPlatform: () => false);
      expect(b.isSupportedPlatform, isFalse);
      expect(await b.availability(), HcAvailability.unsupported);
    });

    test('decodes status and routes from the platform', () async {
      const channel = MethodChannel('test/health_connect');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,
          (call) async {
        switch (call.method) {
          case 'getStatus':
            return {'status': 'available', 'sdkInt': 34};
          case 'readRoute':
            return {
              'status': 'data',
              't': [1000, 2000],
              'lat': [51.5, 51.6],
              'lng': [-0.1, -0.2],
              'acc': [4.0, double.nan],
            };
          case 'requestRouteConsent':
            return {'status': 'denied'};
          case 'readSessions':
            return [
              {
                'id': 'x', 'type': 'walking', 'startMs': 1, 'endMs': 2, 'lastModifiedMs': 3,
                'originPackage': 'com.strava', 'recordingMethod': 'automatic',
              },
              {'id': 'bad'},
            ];
        }
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      final b = MethodChannelHealthConnectBridge(channel: channel, isSupportedPlatform: () => true);
      expect(await b.availability(), HcAvailability.available);
      final r = await b.readRoute('x');
      expect(r, isA<HcRouteData>());
      final pts = (r as HcRouteData).points;
      expect(pts.map((p) => p.tMs), [1000, 2000]);
      expect(pts.first.accuracyM, 4.0);
      expect(pts.last.accuracyM, isNull);
      expect(await b.requestRouteConsent('x'), isA<HcRouteDenied>());
      final sessions = await b.readSessions(sinceMs: 0, untilMs: 10);
      expect(sessions.map((s) => s.versionKey), ['x@3']);
    });
  });
}
