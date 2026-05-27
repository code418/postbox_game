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
}
