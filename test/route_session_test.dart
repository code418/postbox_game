import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/route/route_session.dart';

/// Pins the construction-time clamps on RouteSession. A caller passing
/// out-of-range corridorMetres / detourMinutes (e.g. a future deep-link or
/// shared-state restore) must never reach the server with values outside
/// the bounds the `routePostboxes` callable validates, or every preview
/// fetch would fail invalid-argument before the slider clamped it back.

const _start = LatLng(51.5074, -0.1278);
const _dest = LatLng(51.5200, -0.1100);

void main() {
  group('RouteSession constructor clamps', () {
    test('corridorMetres clamped to the [50, 500] range', () {
      expect(
        RouteSession(start: _start, destination: _dest, corridorMetres: 5)
            .corridorMetres,
        equals(50),
      );
      expect(
        RouteSession(start: _start, destination: _dest, corridorMetres: 5000)
            .corridorMetres,
        equals(500),
      );
      // In-range values pass through unchanged.
      expect(
        RouteSession(start: _start, destination: _dest, corridorMetres: 200)
            .corridorMetres,
        equals(200),
      );
    });

    test('detourMinutes clamped to the [0, 120] range', () {
      expect(
        RouteSession(start: _start, destination: _dest, detourMinutes: -10)
            .detourMinutes,
        equals(0),
      );
      expect(
        RouteSession(start: _start, destination: _dest, detourMinutes: 500)
            .detourMinutes,
        equals(120),
      );
      expect(
        RouteSession(start: _start, destination: _dest, detourMinutes: 30)
            .detourMinutes,
        equals(30),
      );
    });

    test('defaults match the server-allowed mid-range values', () {
      // Drift between the Dart defaults and the server's accepted range
      // (corridor 50–500, detour 0–120) would mean a fresh session fails the
      // very first routePostboxes call. Pin both.
      final s = RouteSession(start: _start, destination: _dest);
      expect(s.corridorMetres, equals(200));
      expect(s.detourMinutes, equals(0));
      expect(s.mode, equals(RouteMode.corridor));
      expect(s.pace, equals(RoutePace.walk));
    });
  });

  group('RouteSession.speedKmh', () {
    test('walk → 4.5 km/h', () {
      final s = RouteSession(start: _start, destination: _dest);
      expect(s.speedKmh, equals(4.5));
    });
    test('jog → 8.5 km/h', () {
      final s = RouteSession(
        start: _start,
        destination: _dest,
        pace: RoutePace.jog,
      );
      expect(s.speedKmh, equals(8.5));
    });
  });

  group('paceEtaLabel', () {
    String walk(double m) =>
        paceEtaLabel(distanceMetres: m, speedKmh: 4.5, pace: RoutePace.walk);
    String jog(double m) =>
        paceEtaLabel(distanceMetres: m, speedKmh: 8.5, pace: RoutePace.jog);

    test('non-finite distance → "..."', () {
      expect(walk(double.infinity), equals('...'));
      expect(walk(double.nan), equals('...'));
    });

    test('sub-minute distance shows "< 1 min", never "≈ 0 min"', () {
      // 30 m (the claim radius) is ~24 s at a walk and ~13 s at a jog. The live
      // route screen previously rounded these to "≈ 0 min", which the preview
      // screen had already fixed — this pins both surfaces to the same rule.
      expect(walk(30), equals('< 1 min walking'));
      expect(jog(30), equals('< 1 min jogging'));
      // Just under the one-minute threshold (74 m at a walk ≈ 59 s).
      expect(walk(74), equals('< 1 min walking'));
      expect(walk(74), isNot(contains('0 min')));
    });

    test('at/over one minute rounds to whole minutes', () {
      // 75 m at 4.5 km/h (1.25 m/s) is exactly 60 s → 1 min.
      expect(walk(75), equals('≈ 1 min walking'));
      // 2700 m at a walk is 36 min.
      expect(walk(2700), equals('≈ 36 min walking'));
    });

    test('verb follows pace', () {
      expect(walk(5000), contains('walking'));
      expect(jog(5000), contains('jogging'));
    });
  });

  group('routeTimeEstimate', () {
    String est({
      double? distM = 2700, // 36 min at a walk
      RouteMode mode = RouteMode.corridor,
      int detour = 0,
    }) =>
        routeTimeEstimate(
          directDistanceMetres: distM,
          speedKmh: 4.5,
          pace: RoutePace.walk,
          mode: mode,
          detourMinutes: detour,
        );

    test('null distance → "–" (no result yet, distinct from "...")', () {
      expect(est(distM: null), equals('–'));
    });

    test('corridor mode shows only the direct ETA', () {
      expect(est(mode: RouteMode.corridor), equals('≈ 36 min walking'));
    });

    test('detour mode appends the detour budget so the time is not understated',
        () {
      expect(
        est(mode: RouteMode.detour, detour: 30),
        equals('≈ 36 min walking + up to 30 min detours'),
      );
    });

    test('detour mode with a zero budget shows only the direct ETA', () {
      expect(est(mode: RouteMode.detour, detour: 0), equals('≈ 36 min walking'));
    });

    test('corridor mode ignores any stale detourMinutes', () {
      // detourMinutes>0 should set mode to detour in the UI, but guard anyway.
      expect(est(mode: RouteMode.corridor, detour: 30),
          equals('≈ 36 min walking'));
    });
  });
}
