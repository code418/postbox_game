import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/services/connectivity_service.dart';
import 'package:postbox_game/services/perf_service.dart';
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
class PostboxMap extends StatefulWidget {
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
  State<PostboxMap> createState() => _PostboxMapState();
}

class _PostboxMapState extends State<PostboxMap> {
  // Internal controller used when the caller hasn't supplied one, so we can
  // reposition the camera when `center` changes after first build (FlutterMap's
  // initialCenter is only read once, so prop changes would otherwise be ignored).
  MapController? _internalController;

  MapController get _effectiveController =>
      widget.mapController ?? (_internalController ??= MapController());

  // Times a sampled subset of tile fetches into the `map.tileLoad` Performance
  // trace. Held in state so the sampling counter survives rebuilds. flutter_map
  // still sets the OSM-required 'User-Agent' header on it (headers.putIfAbsent),
  // and the timing path only *observes* loads — it never replaces the real
  // tile-rendering provider flutter_map receives.
  final _TimingNetworkTileProvider _tileProvider = _TimingNetworkTileProvider();

  @override
  void didUpdateWidget(PostboxMap old) {
    super.didUpdateWidget(old);
    // Move the camera when the caller passes a meaningfully different center.
    // Without this, rescanning from a new location would leave the map stuck
    // on the original center because FlutterMap ignores post-init option changes.
    if (old.center.latitude != widget.center.latitude ||
        old.center.longitude != widget.center.longitude) {
      // Schedule after frame so flutter_map's internal state is ready.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        try {
          _effectiveController.move(widget.center, _effectiveController.camera.zoom);
        } catch (_) {
          // Controller may not be attached to a map yet; safe to ignore.
        }
      });
    }
  }

  @override
  void dispose() {
    _internalController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;

    // Offline, live OSM tile fetches can only fail, leaving a dead grey card
    // (the built-in disk cache covers previously seen areas only). Drop the
    // tile layer entirely and keep the geometry overlays (radius circles,
    // markers, routes) legible on a flat themed background instead.
    // ConnectivityService is optimistic (defaults online, fails open), so
    // this only engages when the device definitely has no transport, and the
    // ValueListenable rebuild restores tiles the moment the link returns.
    return ValueListenableBuilder<bool>(
      valueListenable: ConnectivityService.instance.online,
      builder: (context, online, _) => FlutterMap(
        mapController: _effectiveController,
        options: MapOptions(
          initialCenter: widget.center,
          initialZoom: widget.zoom,
          // Hard cap: OSM tiles show postbox POI icons at zoom ≥ 18, which would
          // reveal exact postbox locations. 17 is the maximum safe level.
          maxZoom: 17,
          onTap: widget.onTap,
          interactionOptions:
              widget.interactionOptions ?? const InteractionOptions(),
          backgroundColor: online
              ? const Color(0xFFE0E0E0) // flutter_map's default canvas
              : scheme.surfaceContainerHighest,
        ),
        children: [
          if (online)
            TileLayer(
              urlTemplate: _defaultTileUrl,
              tileProvider: _tileProvider,
              // Must match the Android applicationId / iOS bundle id so OSM can
              // attribute tile requests correctly per their tile-usage policy.
              userAgentPackageName: 'com.code418.postbox_game',
              // maxNativeZoom matches maxZoom so tiles are never upscaled past 17
              // and no higher-zoom tile requests are ever made.
              maxNativeZoom: 17,
              maxZoom: 17,
              tileBuilder: isDark ? _darkTileBuilder : null,
            ),
          if (widget.polygons.isNotEmpty)
            PolygonLayer(polygons: widget.polygons),
          if (widget.polylines.isNotEmpty)
            PolylineLayer(polylines: widget.polylines),
          if (widget.circleMarkers.isNotEmpty)
            CircleLayer(circles: widget.circleMarkers),
          if (widget.markers.isNotEmpty) MarkerLayer(markers: widget.markers),
          // Attribution (or its offline stand-in) kept above the JamesStrip
          // clearance area. No tiles rendered → nothing to attribute.
          Padding(
            padding: EdgeInsets.only(bottom: widget.bottomPadding),
            child: online
                ? RichAttributionWidget(
                    attributions: [
                      TextSourceAttribution('OpenStreetMap contributors'),
                    ],
                  )
                : const Align(
                    alignment: Alignment.bottomCenter,
                    child: _OfflineMapHint(),
                  ),
          ),
        ],
      ),
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

/// Pill shown in the attribution slot while the map is tile-less offline.
/// Mirrors the StaleDataChip visual language; IgnorePointer so it never
/// swallows map taps.
class _OfflineMapHint extends StatelessWidget {
  const _OfflineMapHint();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined,
                  size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                'Offline — map unavailable',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A [NetworkTileProvider] that times a sampled subset of tile fetches into the
/// `map.tileLoad` Performance trace (attribute: `zoom`).
///
/// flutter_map calls [getImageWithCancelLoadingSupport] for network providers;
/// we forward to `super` (so rendering is unchanged) and, for ~1 tile in 10,
/// attach a second [ImageStreamListener] to the same provider to observe when
/// the load finishes. The image cache dedupes by key, so the observing resolve
/// does not trigger an extra network request. Sampling keeps trace overhead and
/// volume low.
class _TimingNetworkTileProvider extends NetworkTileProvider {
  _TimingNetworkTileProvider();

  int _seq = 0;

  @override
  ImageProvider getImageWithCancelLoadingSupport(
    TileCoordinates coordinates,
    TileLayer options,
    Future<void> cancelLoading,
  ) {
    final provider =
        super.getImageWithCancelLoadingSupport(coordinates, options, cancelLoading);
    if (_seq++ % 10 == 0) {
      _time(provider, coordinates.z);
    }
    return provider;
  }

  void _time(ImageProvider provider, int zoom) {
    PerfService.start(
      PerfTraces.mapTileLoad,
      attributes: {PerfTraces.attrZoom: zoom.toString()},
    ).then((handle) {
      final stream = provider.resolve(const ImageConfiguration());
      ImageStreamListener? listener;
      void finish() {
        if (listener != null) {
          stream.removeListener(listener!);
          listener = null;
          unawaited(handle.stop());
        }
      }

      listener = ImageStreamListener(
        (_, __) => finish(),
        onError: (_, __) => finish(),
      );
      stream.addListener(listener!);
    });
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
