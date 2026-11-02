import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/activity/activity_helpers.dart';
import 'package:postbox_game/services/health_connect_bridge.dart';

const _allow = ['com.fitbit.FitbitMobile', 'com.strava'];
const _hour = 3600 * 1000;
const _grace = 36 * _hour;

HcSession _session({
  String id = 's1',
  String type = 'running',
  int startMs = 0,
  int endMs = 30 * 60 * 1000,
  int lastModifiedMs = 1,
  String origin = 'com.fitbit.FitbitMobile',
  String rm = 'active',
}) =>
    HcSession(
      id: id,
      type: type,
      startMs: startMs,
      endMs: endMs,
      lastModifiedMs: lastModifiedMs,
      originPackage: origin,
      recordingMethod: rm,
    );

const _mLat = 111319.5;
HcRoutePoint _east(double metres, int tMs, {double lat = 51.5, double lng = -0.12, double? acc}) =>
    HcRoutePoint(tMs, lat, lng + metres / (_mLat * math.cos(lat * math.pi / 180)), acc);

void main() {
  group('eligibleSessions', () {
    final now = 10 * _hour;
    List<String> ids(List<HcSession> all, {Set<String> processed = const {}}) =>
        eligibleSessions(all, nowMs: now, graceMs: _grace, originAllowlist: _allow, processedKeys: processed)
            .map((s) => s.id)
            .toList();

    test('keeps a recent on-foot session from an allow-listed app', () {
      expect(ids([_session(startMs: now - _hour, endMs: now - _hour + 1800000)]), ['s1']);
    });

    test('drops other sports, manual entries, unknown apps and processed versions', () {
      final base = _session(startMs: now - _hour, endMs: now - _hour + 1800000);
      expect(ids([_session(type: 'biking', startMs: base.startMs, endMs: base.endMs)]), isEmpty);
      expect(ids([_session(rm: 'manual', startMs: base.startMs, endMs: base.endMs)]), isEmpty);
      expect(ids([_session(origin: 'com.example.faker', startMs: base.startMs, endMs: base.endMs)]), isEmpty);
      expect(ids([base], processed: {base.versionKey}), isEmpty);
      // A rewritten record is a new version and comes back.
      final rewritten = _session(startMs: base.startMs, endMs: base.endMs, lastModifiedMs: 2);
      expect(ids([rewritten], processed: {base.versionKey}), ['s1']);
    });

    test('drops sessions outside the claim window, in the future, too short or too long', () {
      expect(ids([_session(startMs: now - _grace - 2 * _hour, endMs: now - _grace - _hour)]), isEmpty);
      expect(ids([_session(startMs: now, endMs: now + _hour)]), isEmpty);
      expect(ids([_session(startMs: now - _hour, endMs: now - _hour + 60000)]), isEmpty);
      expect(ids([_session(startMs: now - 14 * _hour, endMs: now - _hour)]), isEmpty);
    });

    test('orders newest first', () {
      final a = _session(id: 'old', startMs: now - 5 * _hour, endMs: now - 4 * _hour);
      final b = _session(id: 'new', startMs: now - 2 * _hour, endMs: now - _hour);
      expect(ids([a, b]), ['new', 'old']);
    });
  });

  group('simplifyRoute', () {
    test('collapses a straight line but keeps the endpoints and a fix every minute', () {
      final pts = [for (var i = 0; i <= 600; i++) _east(i * 2.0, i * 1000)]; // 10 min, 1 Hz
      final out = simplifyRoute(pts);
      expect(out.first.tMs, 0);
      expect(out.last.tMs, 600000);
      expect(out.length, lessThan(20));
      for (var i = 1; i < out.length; i++) {
        expect(out[i].tMs - out[i - 1].tMs, lessThanOrEqualTo(60000));
      }
    });

    test('keeps corners that deviate beyond the tolerance', () {
      final pts = <HcRoutePoint>[
        for (var i = 0; i <= 10; i++) _east(i * 10.0, i * 1000),
        // Turn north 100 m at the corner.
        for (var i = 1; i <= 10; i++)
          HcRoutePoint(10000 + i * 1000, 51.5 + i * 10 / _mLat, _east(100, 0).lng),
      ];
      final out = simplifyRoute(pts);
      expect(out.any((p) => p.tMs == 10000), isTrue, reason: 'the corner must survive');
      expect(out.length, lessThan(pts.length));
    });

    test('drops imprecise and non-finite fixes and sorts by time', () {
      final out = simplifyRoute([
        _east(20, 2000),
        _east(0, 0),
        HcRoutePoint(1000, double.nan, -0.12),
        _east(10, 1500, acc: 120),
      ]);
      expect(out.map((p) => p.tMs), [0, 2000]);
    });

    test('raises the tolerance until under the point cap', () {
      final rnd = math.Random(7);
      final pts = [
        for (var i = 0; i < 3000; i++)
          HcRoutePoint(i * 500, 51.5 + (rnd.nextDouble() - 0.5) * 0.002, -0.12 + i * 0.00002)
      ];
      final out = simplifyRoute(pts, maxPoints: 400, maxGapMs: 1 << 30);
      expect(out.length, lessThanOrEqualTo(400));
      expect(out.first.tMs, 0);
      expect(out.last.tMs, pts.last.tMs);
    });
  });

  test('encodeRoutePayload builds the compact wire format', () {
    final s = _session(startMs: 1000, endMs: 400000);
    final p = encodeRoutePayload(s, [HcRoutePoint(1000, 51.1234567, -0.1234567), HcRoutePoint(61000, 51.2, -0.2)]);
    expect(p['source'], 'health_connect');
    final session = p['session']! as Map;
    expect(session['id'], 's1');
    expect(session['exerciseType'], 'running');
    expect(session['recordingMethod'], 'active');
    final route = p['route']! as Map;
    expect(route['dtMs'], [0, 60000]);
    expect(route['lat'], [51.123457, 51.2]);
    expect(route['lng'], [-0.123457, -0.2]);
  });

  group('ActivityCandidate', () {
    final raw = {
      'token': 't',
      'key': 'k',
      'passedAtMs': 5,
      'claimDate': '2026-11-02',
      'boxes': [
        {'monarch': 'VR', 'points': 7},
        {'points': 2},
      ],
    };
    test('parses a server DTO with its session and round-trips through JSON', () {
      final c = ActivityCandidate.tryParse(raw, session: _session())!;
      expect(c.totalPoints, 9);
      expect(c.boxes.first.monarch, 'VR');
      expect(c.boxes.last.monarch, isNull);
      final again = ActivityCandidate.tryParse(c.toJson())!;
      expect(again.key, 'k');
      expect(again.sessionId, 's1');
      expect(again.exerciseType, 'running');
    });
    test('rejects malformed input', () {
      expect(ActivityCandidate.tryParse({'token': 't'}, session: _session()), isNull);
      expect(ActivityCandidate.tryParse({...raw, 'boxes': []}, session: _session()), isNull);
      expect(ActivityCandidate.tryParse(raw), isNull, reason: 'no session info');
    });
  });

  test('candidateStatus', () {
    final c = ActivityCandidate.tryParse({
      'token': 't', 'key': 'k', 'passedAtMs': 0, 'claimDate': '2026-11-02',
      'boxes': [{'points': 2}],
    }, session: _session())!;
    expect(candidateStatus(c, nowMs: _hour, graceMs: _grace), CandidateStatus.claimable);
    expect(candidateStatus(c, nowMs: _grace + 1, graceMs: _grace), CandidateStatus.expired);
    expect(candidateStatus(c, nowMs: 0, graceMs: _grace, claimedKeys: {'k'}), CandidateStatus.claimed);
    expect(candidateStatus(c, nowMs: 0, graceMs: _grace, dismissedKeys: {'k'}), CandidateStatus.dismissed);
  });

  test('autoCheckDue debounces to 20 minutes and tolerates a clock going back', () {
    expect(autoCheckDue(null, 0), isTrue);
    expect(autoCheckDue(0, 19 * 60000), isFalse);
    expect(autoCheckDue(0, 20 * 60000), isTrue);
    expect(autoCheckDue(1000000, 0), isTrue);
  });

  group('healthConnectSettingsAction', () {
    const read = HealthConnectPermissions.readExercise;
    const routes = HealthConnectPermissions.readExerciseRoutes;
    HealthConnectSettingsAction a(HcAvailability av, Set<String> g, bool opted) =>
        healthConnectSettingsAction(availability: av, granted: g, optedIn: opted);
    test('covers every state', () {
      expect(a(HcAvailability.unsupported, {}, false), HealthConnectSettingsAction.none);
      expect(a(HcAvailability.notInstalled, {}, false), HealthConnectSettingsAction.install);
      expect(a(HcAvailability.updateRequired, {}, true), HealthConnectSettingsAction.update);
      expect(a(HcAvailability.available, {}, true), HealthConnectSettingsAction.connect);
      expect(a(HcAvailability.available, {read}, false), HealthConnectSettingsAction.connect,
          reason: 'a device grant made by another account does not opt this one in');
      expect(a(HcAvailability.available, {read}, true), HealthConnectSettingsAction.grantRoutes);
      expect(a(HcAvailability.available, {read, routes}, true), HealthConnectSettingsAction.manage);
    });
  });

  test('labels are friendly, in voice and free of em-dashes', () {
    expect(originLabel('com.fitbit.FitbitMobile'), 'Fitbit');
    expect(originLabel('com.sec.android.app.shealth'), 'Samsung Health');
    expect(originLabel('x.y'), 'a fitness app');
    expect(sessionNoun('hiking'), 'hike');
    for (final v in ['manual_entry', 'origin_not_supported', 'expired', 'implausible_speed', 'no_route',
        'consent_required', 'route_too_large', 'whatever']) {
      expect(verdictLabel(v), isNot(contains('—')));
      expect(verdictLabel(v), isNotEmpty);
    }
    expect(clockTime(DateTime(2026, 11, 2, 7, 5).millisecondsSinceEpoch), '07:05');
    expect(sessionTitle(_session(type: 'walking', startMs: DateTime(2026, 11, 2, 18).millisecondsSinceEpoch)),
        'Evening walk');
  });

  test('eligible exercise types are walking, running and hiking only', () {
    expect(eligibleExerciseTypes, ['walking', 'running', 'hiking']);
  });
}
