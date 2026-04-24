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
    _compassSub = FlutterCompass.events?.listen((event) {
      final h = event.heading;
      if (h == null) return;
      // Throttle updates — skip if heading delta < 5 degrees.
      if (lastHeading != null && (h - lastHeading!).abs() < 5) return;
      lastHeading = h;
      if (mounted) setState(() => _heading = h);
    });
  }

  Future<void> _scan() async {
    if (_stage == _CompassStage.searching) return;
    setState(() => _stage = _CompassStage.searching);
    Analytics.scanStarted();
    try {
      final position = await getPosition(forceLocationManager: true);
      final result = await _callable.call(<String, dynamic>{
        'lat': position.latitude,
        'lng': position.longitude,
        'meters': AppPreferences.nearbyRadiusMeters,
      });
      if (!mounted) return;
      final counts = result.data['counts'] ?? {};
      final compassRaw = result.data['compass'] ?? {};
      setState(() {
        // Cloud Functions serialise JS numbers as either int or double;
        // `as int?` would throw on a double, so normalise via num.
        _totalCount = (counts['total'] as num?)?.toInt() ?? 0;
        _compassCounts = {
          for (final e in (compassRaw as Map).entries)
            e.key as String: (e.value as num).toInt(),
        };
        _stage = _CompassStage.results;
      });
      // Haptic pulse to signal scan complete.
      HapticFeedback.lightImpact();
    } catch (e) {
      debugPrint('Wear compass scan error: $e');
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() => _stage = _CompassStage.error);
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
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 32, color: Colors.red),
              const SizedBox(height: WearSpacing.md),
              Text(
                'Scan failed',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: WearSpacing.sm),
              Text(
                'Tap to retry',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
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
              color: Colors.white.withValues(alpha: 0.3),
            ),
            const SizedBox(height: WearSpacing.md),
            Text(
              'None nearby',
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
                  _totalCount == 1 ? 'nearby' : 'nearby',
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
