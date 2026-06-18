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

/// Human-readable ETA label for travelling [distanceMetres] at [speedKmh]
/// (km/h) on foot, e.g. `"≈ 12 min walking"` / `"< 1 min jogging"`.
///
/// Sub-minute distances render as `"< 1 min <verb>"` rather than rounding to
/// `"≈ 0 min <verb>"`, which reads as either "instant" or "unknown" — the
/// smallest meaningful route is ~30 m (the claim radius), which is ~24 s at a
/// walk. Returns `"..."` for a non-finite distance (e.g. before the first GPS
/// fix). Shared by [RoutePreviewScreen] and [LiveRouteScreen] so the two
/// surfaces can never drift on this boundary again.
String paceEtaLabel({
  required double distanceMetres,
  required double speedKmh,
  required RoutePace pace,
}) {
  if (!distanceMetres.isFinite) return '...';
  final speedMps = speedKmh * 1000 / 3600;
  final seconds = distanceMetres / speedMps;
  final verb = pace == RoutePace.jog ? 'jogging' : 'walking';
  if (seconds < 60) return '< 1 min $verb';
  return '≈ ${(seconds / 60).round()} min $verb';
}

/// Full preview time estimate: the direct walking/jogging ETA, plus the detour
/// budget when one is set in detour mode.
///
/// In detour mode the route's actual time can be up to [detourMinutes] longer
/// than the straight-line ETA, so showing only the direct figure understates
/// the walk (e.g. a 30-min detour budget previously still read "≈ 12 min
/// walking"). Corridor mode adds no time budget (it widens the search band, not
/// the time), so it shows only the direct ETA. Returns `"–"` before the first
/// [directDistanceMetres] is known — distinct from [paceEtaLabel]'s `"..."`
/// sentinel for a non-finite distance. Shared/pure so the maths stays
/// unit-testable without pumping [RoutePreviewScreen].
String routeTimeEstimate({
  required double? directDistanceMetres,
  required double speedKmh,
  required RoutePace pace,
  required RouteMode mode,
  required int detourMinutes,
}) {
  if (directDistanceMetres == null) return '–';
  final base = paceEtaLabel(
    distanceMetres: directDistanceMetres,
    speedKmh: speedKmh,
    pace: pace,
  );
  if (mode == RouteMode.detour && detourMinutes > 0) {
    return '$base + up to $detourMinutes min detours';
  }
  return base;
}
