import 'package:latlong2/latlong.dart';

enum RoutePace { walk, jog } // 4.5 km/h vs 8.5 km/h
enum RouteMode { corridor, detour }

/// Mutable session holder for one user-initiated route attempt.
///
/// Passed by reference through the route screens so each screen can read and
/// update the user's choices without copying. NOT immutable by design.
class RouteSession {
  final LatLng start;
  final LatLng destination;

  /// User-friendly name for the destination (e.g. from Nominatim reverse
  /// geocoding). Null when the user tapped a raw map point.
  String? destinationLabel;

  /// Whether to keep postboxes within a corridor either side of the straight
  /// line, or to allow a maximum detour from the direct route.
  RouteMode mode;

  /// Half-width of the corridor in metres (corridor mode only).
  /// Clamped to [50, 500]; default 200.
  int corridorMetres;

  /// Maximum extra minutes over the direct walking time (detour mode only).
  /// Clamped to [0, 120]; default 0.
  int detourMinutes;

  RoutePace pace;

  // ── Filled in by RoutePreviewScreen after calling routePostboxes ──────────

  /// Number of postboxes found along the route.
  int? computedCount;

  /// Total points available along the route.
  int? computedPoints;

  /// Straight-line distance between start and destination in metres,
  /// returned by the `routePostboxes` callable.
  num? directDistanceM;

  RouteSession({
    required this.start,
    required this.destination,
    this.destinationLabel,
    this.mode = RouteMode.corridor,
    this.corridorMetres = 200,
    this.detourMinutes = 0,
    this.pace = RoutePace.walk,
  }) {
    // Clamp to valid ranges on construction.
    corridorMetres = corridorMetres.clamp(50, 500);
    detourMinutes = detourMinutes.clamp(0, 120);
  }

  /// Walking/jogging speed in km/h based on the chosen [pace].
  double get speedKmh => pace == RoutePace.jog ? 8.5 : 4.5;
}
