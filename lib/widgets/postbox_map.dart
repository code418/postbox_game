import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/theme.dart';

/// Default tile URL for OpenStreetMap. Replace with a hosted provider
/// (Stadia Maps, Mapbox, MapTiler) for production use.
const String _defaultTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

/// A reusable map widget themed to match the Postbox Game visual style.
///
/// Wraps [FlutterMap] with app-consistent colours and bottom padding so the
/// [JamesStrip] overlay never obscures map content.
///
/// ## Usage ideas across the app
///
/// **Privacy-compatible (no postbox locations revealed):**
/// - Nearby screen: "You Are Here" context map with 540 m scan radius circle.
/// - Nearby screen: sector heatmap overlay — 8 pie-wedge sectors colour-coded
///   by compass-count intensity, giving geographic context to the FuzzyCompass.
/// - Claim screen: 30 m claim-radius visualisation around the user's position.
/// - Settings: scan-radius preview (540 m + 30 m concentric circles).
/// - Settings: map-style preference (standard / satellite / dark tiles).
/// - Intro/onboarding: animated zoom from UK → city → street level to teach
///   the scan concept visually.
/// - Postman James as user-position marker (SVG with head-bob animation).
/// - Map/list toggle on any screen that gains a map view.
///
/// **Requires backend changes:**
/// - Post-claim celebration map showing the just-claimed postbox.
/// - Claimed-postbox trail (chronological polyline of past claims).
/// - "Fill the map" gamification (UK grid cells coloured by claim coverage).
/// - Geographic coverage map on the lifetime leaderboard tab.
/// - Regional leaderboard selector via tappable UK map.
/// - Friend coverage comparison map.
/// - Shareable branded map snapshot after claiming.
/// - Personal claim map / rare-finds map in a profile screen.
class PostboxMap extends StatelessWidget {
  const PostboxMap({
    super.key,
    required this.center,
    this.zoom = 15.0,
    this.markers = const [],
    this.circleMarkers = const [],
    this.polygons = const [],
    this.polylines = const [],
    this.mapController,
    this.onTap,
    this.interactionOptions,
    this.bottomPadding = kJamesStripClearance,
  });

  /// Centre point of the map.
  final LatLng center;

  /// Initial zoom level (default 15 — street level).
  final double zoom;

  /// Markers to render on the map.
  final List<Marker> markers;

  /// Circle overlays (e.g. scan-radius rings).
  final List<CircleMarker> circleMarkers;

  /// Polygon overlays (e.g. sector heatmap wedges).
  final List<Polygon> polygons;

  /// Polyline overlays (e.g. claim trail).
  final List<Polyline> polylines;

  /// Optional controller for programmatic map movement.
  final MapController? mapController;

  /// Called when the user taps on the map background.
  final void Function(TapPosition, LatLng)? onTap;

  /// Interaction flags — pass [InteractionOptions] to restrict gestures
  /// (e.g. disable zoom/pan for a non-interactive preview).
  final InteractionOptions? interactionOptions;

  /// Bottom padding to clear the JamesStrip overlay. Defaults to
  /// [kJamesStripClearance] (80 px).
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return FlutterMap(
      mapController: mapController,
      options: MapOptions(
        initialCenter: center,
        initialZoom: zoom,
        onTap: onTap,
        interactionOptions: interactionOptions ?? const InteractionOptions(),
      ),
      children: [
        TileLayer(
          urlTemplate: _defaultTileUrl,
          userAgentPackageName: 'com.postboxgame.app',
          tileBuilder: isDark ? _darkTileBuilder : null,
        ),
        if (polygons.isNotEmpty) PolygonLayer(polygons: polygons),
        if (polylines.isNotEmpty) PolylineLayer(polylines: polylines),
        if (circleMarkers.isNotEmpty)
          CircleLayer(circles: circleMarkers),
        if (markers.isNotEmpty) MarkerLayer(markers: markers),
        // Attribution kept above the JamesStrip clearance area.
        Padding(
          padding: EdgeInsets.only(bottom: bottomPadding),
          child: const SimpleAttributionWidget(
            source: Text('OpenStreetMap contributors'),
          ),
        ),
      ],
    );
  }

  /// Applies a colour filter to tiles for a basic dark-mode appearance.
  /// For production, switch to a dark tile provider URL instead.
  static Widget _darkTileBuilder(
    BuildContext context,
    Widget tileWidget,
    TileImage tile,
  ) {
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(<double>[
        -0.2, -0.7, -0.1, 0, 255, // red
        -0.2, -0.7, -0.1, 0, 255, // green
        -0.2, -0.7, -0.1, 0, 255, // blue
         0,    0,    0,   1,   0,  // alpha
      ]),
      child: tileWidget,
    );
  }
}

/// Creates a [CircleMarker] styled as a scan-radius ring.
///
/// Use for the 540 m nearby radius or 30 m claim radius.
CircleMarker scanRadiusCircle(
  LatLng center, {
  required double radiusMeters,
  Color? color,
  Color? borderColor,
}) {
  return CircleMarker(
    point: center,
    radius: radiusMeters,
    useRadiusInMeter: true,
    color: (color ?? postalRed).withValues(alpha: 0.08),
    borderColor: borderColor ?? postalRed.withValues(alpha: 0.4),
    borderStrokeWidth: 2,
  );
}
