import 'dart:async';
import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/app_preferences.dart';
import 'package:postbox_game/fuzzy_compass.dart';
import 'package:postbox_game/location_service.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/wear/wear_theme.dart';

enum _CompassStage { initial, searching, results, error }

/// Full-screen fuzzy compass for Wear OS.
///
/// The compass fills the entire round display, rotating with the device
/// heading. Tap to scan; pull down to refresh. The total count of nearby
/// unclaimed postboxes is shown at the centre.
class WearCompassPage extends StatefulWidget {
  const WearCompassPage({super.key});

  @override
  State<WearCompassPage> createState() => _WearCompassPageState();
}

class _WearCompassPageState extends State<WearCompassPage> {
  _CompassStage _stage = _CompassStage.initial;
  Map<String, int> _compassCounts = {};
  int _totalCount = 0;
  double? _heading;
  StreamSubscription<CompassEvent>? _compassSub;
  /// Short human-readable error message shown on the [_CompassStage.error]
  /// screen. Populated by [_scan] when a [LocationServiceException] gives us
  /// a more specific cause than the generic "Scan failed".
  String? _errorMessage;

  final HttpsCallable _callable =
      FirebaseFunctions.instance.httpsCallable('nearbyPostboxes');

  @override
  void initState() {
    super.initState();
    _startCompassListener();
  }

  @override
  void dispose() {
    _compassSub?.cancel();
    super.dispose();
  }

  void _startCompassListener() {
    double? lastHeading;
    // FlutterCompass.events throws a MissingPluginException in test envs
    // without the platform channel — guard the listen() call so a missing
    // magnetometer doesn't crash the wear page on first build.
    try {
      _compassSub = FlutterCompass.events?.listen((event) {
        final h = event.heading;
        if (h == null) return;
        // Throttle updates — skip if heading delta < 5 degrees. Use modular
        // distance so 359°→1° (delta = 2°) doesn't trip the naive abs-diff (358°).
        if (lastHeading != null &&
            compassHeadingDelta(h, lastHeading!) < 5) {
          return;
        }
        lastHeading = h;
        if (mounted) setState(() => _heading = h);
      });
    } catch (_) {
      _compassSub = null;
    }
  }

  Future<void> _scan() async {
    if (_stage == _CompassStage.searching) return;
    setState(() {
      _stage = _CompassStage.searching;
      _errorMessage = null;
    });
    // Wear compass uses nearbyRadiusMeters (540 m) like the phone's Nearby
    // tab, not claimRadiusMeters — log the matching analytics event so
    // dashboards group it with phone-Nearby instead of phone-Claim.
    Analytics.nearbyStarted();
    try {
      final position = await getPosition(forceLocationManager: true);
      final result = await _callable.call(<String, dynamic>{
        'lat': position.latitude,
        'lng': position.longitude,
        'meters': AppPreferences.nearbyRadiusMeters,
      });
      if (!mounted) return;
      final counts = result.data['counts'] ?? {};
      final points = (result.data['points'] as Map?) ?? const {};
      final compassRaw = result.data['compass'] ?? {};
      int asInt(dynamic v) => (v as num?)?.toInt() ?? 0;
      final total = asInt(counts['total']);
      final claimed = asInt(counts['claimedToday']);
      final minPoints = asInt(points['min']);
      final maxPoints = asInt(points['max']);
      setState(() {
        // Show unclaimed-only count so it agrees with the compass sectors,
        // which only render directions of postboxes still claimable today.
        _totalCount = (total - claimed).clamp(0, total);
        // Tolerate a missing/null sector value rather than crashing the scan
        // (matches the `asInt` helper used by the phone Nearby screen).
        _compassCounts = {
          for (final e in (compassRaw as Map).entries)
            e.key as String: asInt(e.value),
        };
        _stage = _CompassStage.results;
      });
      if (total > 0) {
        Analytics.nearbyComplete(
          count: total,
          claimedToday: claimed,
          minPoints: minPoints,
          maxPoints: maxPoints,
        );
      } else {
        Analytics.nearbyEmpty();
      }
      // Haptic pulse to signal scan complete.
      HapticFeedback.lightImpact();
    } on LocationServiceException catch (e) {
      debugPrint('Wear compass location error: $e');
      if (e.kind == LocationErrorKind.permissionPermanentlyDenied) {
        unawaited(Analytics.locationPermissionPermanentlyDenied());
      }
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() {
        _stage = _CompassStage.error;
        _errorMessage = switch (e.kind) {
          LocationErrorKind.servicesDisabled => 'Turn on location',
          LocationErrorKind.permissionPermanentlyDenied =>
            'Location denied. Enable in settings.',
          LocationErrorKind.permissionDenied => 'Location needed to scan',
        };
      });
    } catch (e) {
      debugPrint('Wear compass scan error: $e');
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() {
        _stage = _CompassStage.error;
        _errorMessage = 'Scan failed';
      });
    } finally {
      // Safety net: ensure we never get permanently stuck on 'searching' if
      // an unexpected Dart Error bypasses the catch block above. Without this
      // the GestureDetector's `onTap` is null and the user can't re-scan.
      if (mounted && _stage == _CompassStage.searching) {
        setState(() {
          _stage = _CompassStage.error;
          _errorMessage ??= 'Scan failed';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _stage == _CompassStage.searching ? null : _scan,
      child: Container(
        color: Colors.black,
        child: _buildContent(context),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    switch (_stage) {
      case _CompassStage.initial:
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.explore,
                size: 40,
                color: postalRed.withValues(alpha: 0.7),
              ),
              const SizedBox(height: WearSpacing.md),
              Text(
                'Tap to scan',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: WearSpacing.sm),
              Text(
                'nearby postboxes',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );

      case _CompassStage.searching:
        return const Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: postalRed,
            ),
          ),
        );

      case _CompassStage.results:
        return _buildCompass(context);

      case _CompassStage.error:
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: WearSpacing.lg),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 32, color: Colors.red),
                const SizedBox(height: WearSpacing.md),
                Text(
                  _errorMessage ?? 'Scan failed',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: WearSpacing.sm),
                Text(
                  'Tap to retry',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        );
    }
  }

  Widget _buildCompass(BuildContext context) {
    if (_totalCount == 0) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.location_off,
              size: 32,
              color: Colors.white.withValues(alpha: 0.7),
            ),
            const SizedBox(height: WearSpacing.md),
            Text(
              'None to find',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: WearSpacing.sm),
            Text(
              'Tap to rescan',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    }

    final sectors = FuzzyCompass.to8Sectors(_compassCounts);
    final sectorValues = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW']
        .map((d) => sectors[d] ?? 0)
        .toList();
    final rotation = _heading != null ? (_heading! * pi / 180) : 0.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest.shortestSide;
        return Stack(
          alignment: Alignment.center,
          children: [
            // Full-screen compass
            Transform.rotate(
              angle: -rotation,
              child: CustomPaint(
                size: Size(size, size),
                // Pass rotation so the painter counter-rotates the 'N' label;
                // otherwise it spins with the canvas and is unreadable whenever
                // the watch is not pointing north.
                painter: FuzzyCompassPainter(
                  sectors: sectorValues,
                  rotation: rotation,
                  // Without this the painter falls back to its near-black
                  // default, making the background sector ring (and the
                  // counter-rotated 'N' label backdrop) invisible against the
                  // watch's black canvas. Use the theme's onSurface (white).
                  onSurface: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
            // Centre count overlay (doesn't rotate)
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$_totalCount',
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                Text(
                  'to find',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
