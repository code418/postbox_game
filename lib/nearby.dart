import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/app_preferences.dart';
import 'package:postbox_game/james_controller.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:geolocator/geolocator.dart';
import 'package:postbox_game/location_service.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/theme.dart';

import './fuzzy_compass.dart';

enum NearbyStage { initial, searching, results }

class Nearby extends StatefulWidget {
  const Nearby({super.key});

  @override
  NearbyState createState() => NearbyState();
}

class NearbyState extends State<Nearby> {
  int _count = 0;
  int _maxPoints = 0;
  int _minPoints = 0;
  int _claimedToday = 0;
  // Per-cipher totals and claimed-today counts; populated from the server response.
  final Map<String, int> _cipherTotals = {};
  final Map<String, int> _cipherClaimed = {};
  // 16-wind compass counts (N, NNE, NE, …); populated from the server response.
  final Map<String, int> _compassCounts = {};
  DistanceUnit _distanceUnit = DistanceUnit.meters;
  DateTime? _lastScanned;

  // ValueNotifier so compass heading changes only rebuild FuzzyCompass, not the
  // entire results tree. Previously a setState here rebuilt all staggered cards.
  final ValueNotifier<double?> _headingNotifier = ValueNotifier(null);
  StreamSubscription<CompassEvent>? _compassSubscription;
  NearbyStage currentStage = NearbyStage.initial;

  // Throttle heading updates: skip if the delta is <5° to avoid redundant repaints.
  // IndexedStack keeps Nearby mounted even offstage; without this the magnetometer
  // would fire continuously even when the tab is hidden.
  static double _headingDelta(double a, double b) {
    final d = (a - b).abs() % 360;
    return d > 180 ? 360 - d : d;
  }

  @override
  void initState() {
    super.initState();
    _compassSubscription = FlutterCompass.events?.listen((CompassEvent event) {
      final heading = event.heading;
      if (heading == null) return;
      final prev = _headingNotifier.value;
      if (prev == null || _headingDelta(prev, heading) >= 5) {
        _headingNotifier.value = heading;
      }
    });
    AppPreferences.getDistanceUnit().then((unit) {
      if (mounted) setState(() => _distanceUnit = unit);
    });
  }

  @override
  void dispose() {
    _compassSubscription?.cancel();
    _headingNotifier.dispose();
    super.dispose();
  }

  final HttpsCallable callable =
      FirebaseFunctions.instance.httpsCallable('nearbyPostboxes');

  Future<void> _startSearch() async {
    // Guard against concurrent calls (e.g. pull-to-refresh + Refresh button
    // both firing before the next frame rebuilds the UI).
    if (currentStage == NearbyStage.searching) return;
    setState(() => currentStage = NearbyStage.searching);
    Analytics.nearbyStarted();
    try {
      _distanceUnit = await AppPreferences.getDistanceUnit();
      final position = await getPosition();
      final result = await callable.call(<String, dynamic>{
        'lat': position.latitude,
        'lng': position.longitude,
        'meters': AppPreferences.nearbyRadiusMeters,
      });
      if (!mounted) return;
      setState(() {
        _count = result.data['counts']['total'] ?? 0;
        _maxPoints = result.data['points']['max'] ?? 0;
        _minPoints = result.data['points']['min'] ?? 0;
        currentStage = NearbyStage.results;
        for (final dir in const [
          'N', 'NNE', 'NE', 'ENE', 'E', 'ESE',
          'SE', 'SSE', 'S', 'SSW', 'SW', 'WSW',
          'W', 'WNW', 'NW', 'NNW',
        ]) {
          _compassCounts[dir] = result.data['compass'][dir] ?? 0;
        }
        _claimedToday = result.data['counts']['claimedToday'] ?? 0;
        for (final cipher in MonarchInfo.all) {
          _cipherTotals[cipher] = result.data['counts'][cipher] ?? 0;
          _cipherClaimed[cipher] = result.data['counts']['${cipher}_claimed'] ?? 0;
        }
        _lastScanned = DateTime.now();
      });
      if (_count > 0) {
        Analytics.nearbyComplete(
          count: _count,
          claimedToday: _claimedToday,
          minPoints: _minPoints,
          maxPoints: _maxPoints,
        );
      } else {
        Analytics.nearbyEmpty();
      }
      final box = _count == 1 ? 'postbox' : 'postboxes';
      final msg = _count > 0
          ? JamesMessages.nearbyFound(_count, box)
          : JamesMessages.nearbyNoneFound.resolve();
      JamesController.of(context)?.show(msg);
    } on FirebaseFunctionsException catch (e) {
      debugPrint('Firebase functions error: ${e.code} ${e.message}');
      if (!mounted) return;
      final isOffline = e.code == 'unavailable';
      JamesController.of(context)?.show(
        isOffline
            ? JamesMessages.errorOffline.resolve()
            : JamesMessages.nearbyErrorGeneral.resolve(),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isOffline
              ? 'No internet connection. Please try again.'
              : 'Could not fetch postboxes. Please try again.'),
          backgroundColor: Colors.red.shade700,
        ),
      );
      setState(() => currentStage = NearbyStage.initial);
    } catch (e) {
      debugPrint('Error: $e');
      if (!mounted) return;
      final msg = e.toString().contains('permission')
          ? JamesMessages.nearbyErrorPermission.resolve()
          : JamesMessages.nearbyErrorGeneral.resolve();
      JamesController.of(context)?.show(msg);
      // Only surface the message for exceptions thrown with Exception('...')
      // (location-permission errors from getPosition()). PlatformException
      // and other types produce a 'PlatformException(...)' prefix and must
      // not be forwarded to the user.
      final raw = e.toString();
      final isPermanentlyDenied = raw.contains('permanently denied');
      if (isPermanentlyDenied) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Location permission permanently denied.'),
            backgroundColor: Colors.red.shade700,
            action: SnackBarAction(
              label: 'Open Settings',
              textColor: Colors.white,
              onPressed: Geolocator.openAppSettings,
            ),
          ),
        );
      } else {
        final userMsg = raw.startsWith('Exception: ')
            ? raw.replaceFirst('Exception: ', '')
            : 'Could not fetch postboxes. Please try again.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(userMsg),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
      setState(() => currentStage = NearbyStage.initial);
    } finally {
      // Safety net: ensure we never get permanently stuck in 'searching' state
      // if an unexpected Dart Error bypasses the catch blocks above.
      if (mounted && currentStage == NearbyStage.searching) {
        setState(() => currentStage = NearbyStage.initial);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (currentStage) {
      case NearbyStage.initial:
        return _buildInitial(context);
      case NearbyStage.searching:
        return _buildSearching(context);
      case NearbyStage.results:
        return _buildResults(context);
    }
  }

  Widget _buildInitial(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.only(
          top: AppSpacing.xl,
          left: AppSpacing.xl,
          right: AppSpacing.xl,
          bottom: 100,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight - 100),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.location_searching,
                size: 80,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.2)),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Find nearby postboxes',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Scan within ${AppPreferences.formatDistance(AppPreferences.nearbyRadiusMeters, _distanceUnit)} to see which postboxes are around you.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton.icon(
              onPressed: _startSearch,
              icon: const Icon(Icons.search),
              label: const Text('Find nearby postboxes'),
            ),
          ],
        ),
        ),
      ),
    );
  }

  Widget _buildSearching(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: kJamesStripClearance),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: postalRed),
            const SizedBox(height: AppSpacing.md),
            Text('Scanning ${AppPreferences.formatDistance(AppPreferences.nearbyRadiusMeters, _distanceUnit)} radius...'),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    final compassMap = _compassCounts;

    // Show ciphers present in the area, in display order, total count > 0.
    final monarchEntries = MonarchInfo.all
        .map((c) => MapEntry(c, _cipherTotals[c] ?? 0))
        .where((e) => e.value > 0)
        .toList();

    return RefreshIndicator(
      color: postalRed,
      onRefresh: _startSearch,
      child: AnimationLimiter(
      child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(
          top: AppSpacing.md, bottom: 100, left: 0, right: 0),
      children: [
        // Summary card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: postalRed.withValues(alpha:0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.location_on, color: postalRed),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$_count postbox${_count == 1 ? '' : 'es'} nearby',
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                      ),
                      if (_count > 0 && _claimedToday < _count)
                        Text(
                          _maxPoints == _minPoints
                              ? 'Worth $_maxPoints pts'
                              : 'Worth $_minPoints–$_maxPoints pts',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                      if (_lastScanned != null)
                        Text(
                          'Scanned at ${TimeOfDay.fromDateTime(_lastScanned!).format(context)}',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                      if (_claimedToday > 0)
                        Row(
                          children: [
                            const Icon(Icons.lock_clock, size: 12, color: Colors.orange),
                            const SizedBox(width: 4),
                            Text(
                              '$_claimedToday claimed today',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.orange.shade700,
                                  ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: _startSearch,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Refresh'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ),
        ),

        // Empty state
        if (_count == 0)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              children: [
                Icon(Icons.location_off, size: 60,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.2)),
                const SizedBox(height: AppSpacing.md),
                Text(
                  'No postboxes found within ${AppPreferences.formatDistance(AppPreferences.nearbyRadiusMeters, _distanceUnit)}',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Try a different location.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),

        // Monarch breakdown
        if (monarchEntries.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
            child: Text(
              'Postbox types',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          ...monarchEntries.asMap().entries.map((entry) {
            final cipher = entry.value.key;
            final total = entry.value.value;
            final claimed = _cipherClaimed[cipher] ?? 0;
            return AnimationConfiguration.staggeredList(
              position: entry.key,
              duration: const Duration(milliseconds: 375),
              child: SlideAnimation(
                verticalOffset: 50,
                child: FadeInAnimation(
                  child: _monarchCard(context, cipher, total, claimed),
                ),
              ),
            );
          }),
        ],

        // Compass — only shown when there are unclaimed postboxes; the
        // server now returns an unclaimed-only compass so hiding it when
        // everything is claimed avoids showing a blank "No postboxes" disc.
        if (_count > 0 && _claimedToday < _count) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.lg, AppSpacing.md, AppSpacing.xs),
            child: Text(
              'Where to look',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          ValueListenableBuilder<double?>(
            valueListenable: _headingNotifier,
            builder: (_, heading, __) => FuzzyCompass(
              compassCounts: compassMap,
              headingDegrees: heading,
            ),
          ),
        ],

      ],
    ),
      ),
    );
  }

  Widget _monarchCard(BuildContext context, String code, int count, int claimed) {
    final label = MonarchInfo.labels[code] ?? code;
    final color = MonarchInfo.colors[code] ?? postalRed;
    final available = count - claimed;

    Widget? trailing;
    if (MonarchInfo.rareCiphers.contains(code)) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star, size: 14, color: postalGold),
          const SizedBox(width: 2),
          Text(
            'Rare',
            style: TextStyle(
                color: postalGold, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      );
    } else if (MonarchInfo.historicCiphers.contains(code)) {
      trailing = Text(
        'Historic',
        style: TextStyle(
            color: Colors.brown.shade400,
            fontSize: 12,
            fontWeight: FontWeight.w500),
      );
    }

    // Dim the avatar when all are claimed today; show remaining count.
    final allClaimed = available <= 0;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor:
              color.withValues(alpha: allClaimed ? 0.06 : 0.12),
          child: Text(
            allClaimed ? '✓' : '$available',
            style: TextStyle(
              color: allClaimed
                  ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.38)
                  : color,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        title: Text(
          label,
          style: allClaimed
              ? TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.38))
              : null,
        ),
        subtitle: Text(
          allClaimed
              ? '$code · claimed today'
              : claimed > 0
                  ? '$code · ${MonarchInfo.getPoints(code)} pts · $available of $count available'
                  : '$code · ${MonarchInfo.getPoints(code)} pts each',
          style: allClaimed
              ? TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.38))
              : null,
        ),
        trailing: allClaimed ? null : trailing,
      ),
    );
  }
}
