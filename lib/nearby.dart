import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:postbox_game/firebase_functions_eu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/app_preferences.dart';
import 'package:postbox_game/james_controller.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:geolocator/geolocator.dart';
import 'package:postbox_game/location_service.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/reports/report_missing_postbox_screen.dart';
import 'package:postbox_game/services/perf_service.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/widgets/postbox_map.dart';
import 'package:postbox_game/widgets/postbox_marker.dart';
import 'package:postbox_game/widgets/view_toggle.dart';

import './fuzzy_compass.dart';

enum NearbyStage { initial, searching, results }

class Nearby extends StatefulWidget {
  const Nearby({super.key});

  @override
  State<Nearby> createState() => _NearbyState();
}

class _NearbyState extends State<Nearby> {
  int _count = 0;
  int _maxPoints = 0;
  int _minPoints = 0;
  int _claimedToday = 0;
  // Per-cipher totals and claimed-today counts; populated from the server response.
  final Map<String, int> _cipherTotals = {};
  final Map<String, int> _cipherClaimed = {};
  // 16-wind compass counts for unclaimed / claimed postboxes; populated from server response.
  final Map<String, int> _compassCounts = {};
  final Map<String, int> _claimedCompassCounts = {};
  DistanceUnit _distanceUnit = DistanceUnit.meters;
  DateTime? _lastScanned;
  Position? _scanPosition;
  ViewMode _viewMode = ViewMode.list;

  // ValueNotifier so compass heading changes only rebuild FuzzyCompass, not the
  // entire results tree. Previously a setState here rebuilt all staggered cards.
  final ValueNotifier<double?> _headingNotifier = ValueNotifier(null);
  StreamSubscription<CompassEvent>? _compassSubscription;
  NearbyStage currentStage = NearbyStage.initial;

  @override
  void initState() {
    super.initState();
    // FlutterCompass.events is non-null in production but throws a
    // MissingPluginException in test environments without the platform
    // channel. Wrap so a missing magnetometer (test or e.g. desktop runs)
    // doesn't blow up the whole screen on first build.
    try {
      _compassSubscription =
          FlutterCompass.events?.listen((CompassEvent event) {
        final heading = event.heading;
        if (heading == null) return;
        final prev = _headingNotifier.value;
        // Throttle heading updates: skip deltas <5° to avoid redundant repaints.
        // IndexedStack keeps Nearby mounted even offstage; without this the
        // magnetometer would churn rebuilds even when the tab is hidden.
        // Uses the shared, unit-tested helper from fuzzy_compass.dart (also
        // used by live_route_screen) rather than a private duplicate.
        if (prev == null || compassHeadingDelta(prev, heading) >= 5) {
          _headingNotifier.value = heading;
        }
      });
    } catch (_) {
      _compassSubscription = null;
    }
    AppPreferences.getDistanceUnit().then((unit) {
      if (mounted) setState(() => _distanceUnit = unit);
    });
    AppPreferences.getViewMode('nearby').then((mode) {
      if (mounted) setState(() => _viewMode = mode);
    });
  }

  @override
  void dispose() {
    _compassSubscription?.cancel();
    _headingNotifier.dispose();
    super.dispose();
  }

  final HttpsCallable callable =
      appFunctions.httpsCallable('nearbyPostboxes');

  Future<void> _startSearch() async {
    // Guard against concurrent calls (e.g. pull-to-refresh + Refresh button
    // both firing before the next frame rebuilds the UI).
    if (currentStage == NearbyStage.searching) return;
    setState(() => currentStage = NearbyStage.searching);
    Analytics.nearbyStarted();
    try {
      _distanceUnit = await AppPreferences.getDistanceUnit();
      final position = await getPosition();
      if (mounted) setState(() => _scanPosition = position);
      final result = await PerfService.traceAsync(
        PerfTraces.callableNearbyPostboxes,
        (trace) async {
          final r = await callable.call(<String, dynamic>{
            'lat': position.latitude,
            'lng': position.longitude,
            'meters': AppPreferences.nearbyRadiusMeters,
          });
          final total = ((Map<String, dynamic>.from(r.data as Map)['counts']
                  as Map?)?['total'] as num?)
              ?.toInt();
          if (total != null) {
            trace.setMetric(PerfTraces.metricResultsCount, total);
          }
          return r;
        },
        attributes: {
          PerfTraces.attrRadius:
              AppPreferences.nearbyRadiusMeters.round().toString(),
        },
      );
      if (!mounted) return;
      final data = Map<String, dynamic>.from(result.data as Map);
      final counts = Map<String, dynamic>.from(data['counts'] as Map);
      final pts = Map<String, dynamic>.from(data['points'] as Map);
      final compass = data['compass'] != null
          ? Map<String, dynamic>.from(data['compass'] as Map)
          : <String, dynamic>{};
      final claimedCompass = data['claimedCompass'] != null
          ? Map<String, dynamic>.from(data['claimedCompass'] as Map)
          : <String, dynamic>{};
      // Cloud Functions serialise JS numbers as either int or double; assigning
      // a double to a typed int field throws, so normalise every count via num.
      int asInt(dynamic v) => (v as num?)?.toInt() ?? 0;
      setState(() {
        _count = asInt(counts['total']);
        _maxPoints = asInt(pts['max']);
        _minPoints = asInt(pts['min']);
        currentStage = NearbyStage.results;
        for (final dir in const [
          'N',
          'NNE',
          'NE',
          'ENE',
          'E',
          'ESE',
          'SE',
          'SSE',
          'S',
          'SSW',
          'SW',
          'WSW',
          'W',
          'WNW',
          'NW',
          'NNW',
        ]) {
          _compassCounts[dir] = asInt(compass[dir]);
          _claimedCompassCounts[dir] = asInt(claimedCompass[dir]);
        }
        _claimedToday = asInt(counts['claimedToday']);
        for (final cipher in MonarchInfo.all) {
          _cipherTotals[cipher] = asInt(counts[cipher]);
          _cipherClaimed[cipher] = asInt(counts['${cipher}_claimed']);
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
      final String msg;
      if (_count == 0) {
        msg = JamesMessages.nearbyNoneFound.resolve();
      } else if (_claimedToday == _count) {
        msg = JamesMessages.claimErrorAlreadyClaimed.resolve();
      } else {
        final box = _count == 1 ? 'postbox' : 'postboxes';
        msg = JamesMessages.nearbyFound(_count, box);
      }
      if (mounted) JamesController.of(context)?.show(msg);
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
    } on TimeoutException {
      if (!mounted) return;
      JamesController.of(context)
          ?.show(JamesMessages.nearbyErrorGeneral.resolve());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
              'GPS signal timed out. Move to an open area and try again.'),
          backgroundColor: Colors.red.shade700,
        ),
      );
      setState(() => currentStage = NearbyStage.initial);
    } on LocationServiceException catch (e) {
      debugPrint('Location error: $e');
      if (!mounted) return;
      final isPermission =
          e.kind == LocationErrorKind.permissionDenied ||
              e.kind == LocationErrorKind.permissionPermanentlyDenied;
      JamesController.of(context)?.show(isPermission
          ? JamesMessages.nearbyErrorPermission.resolve()
          : JamesMessages.nearbyErrorGeneral.resolve());
      switch (e.kind) {
        case LocationErrorKind.permissionPermanentlyDenied:
          unawaited(Analytics.locationPermissionPermanentlyDenied());
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
        case LocationErrorKind.servicesDisabled:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Location services are disabled.'),
              backgroundColor: Colors.red.shade700,
              action: SnackBarAction(
                label: 'Open Settings',
                textColor: Colors.white,
                onPressed: Geolocator.openLocationSettings,
              ),
            ),
          );
        case LocationErrorKind.permissionDenied:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(e.message),
              backgroundColor: Colors.red.shade700,
            ),
          );
      }
      setState(() => currentStage = NearbyStage.initial);
    } catch (e) {
      // PlatformException and other types must not be forwarded to the user
      // as-is (raw 'PlatformException(...)' prefix would leak).
      debugPrint('Error: $e');
      if (!mounted) return;
      JamesController.of(context)
          ?.show(JamesMessages.nearbyErrorGeneral.resolve());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Could not fetch postboxes. Please try again.'),
          backgroundColor: Colors.red.shade700,
        ),
      );
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
      builder: (context, constraints) {
        // In landscape the body is only a few hundred logical pixels tall, so a
        // full-height centred column pushes the primary CTA below the fold. Lay
        // the illustration beside the text + actions instead so the scan button
        // stays visible. Portrait keeps the original centred column.
        final landscape = constraints.maxWidth > constraints.maxHeight;
        final onSurface = Theme.of(context).colorScheme.onSurface;
        final icon = Icon(Icons.location_searching,
            size: landscape ? 64 : 80, color: onSurface.withValues(alpha: 0.2));
        final title = Text(
          'Find nearby postboxes',
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.bold),
          textAlign: landscape ? TextAlign.start : TextAlign.center,
        );
        final subtitle = Text(
          'Scan within ${AppPreferences.formatDistance(AppPreferences.nearbyRadiusMeters, _distanceUnit)} to see which postboxes are around you.',
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          textAlign: landscape ? TextAlign.start : TextAlign.center,
        );
        final scanButton = FilledButton.icon(
          onPressed: _startSearch,
          icon: const Icon(Icons.search),
          label: const Text('Find nearby postboxes'),
        );
        final routeButton = RemoteConfigService.instance.killSwitchRouteMode
            ? null
            : OutlinedButton.icon(
                onPressed: () => Navigator.pushNamed(context, '/route'),
                icon: const Icon(Icons.directions_walk),
                label: const Text('Walk to a destination'),
              );

        if (landscape) {
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl, AppSpacing.xl, AppSpacing.xl, 100),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                icon,
                const SizedBox(width: AppSpacing.xl),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      title,
                      const SizedBox(height: AppSpacing.sm),
                      subtitle,
                      const SizedBox(height: AppSpacing.lg),
                      scanButton,
                      if (routeButton != null) ...[
                        const SizedBox(height: AppSpacing.sm),
                        routeButton,
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        return SingleChildScrollView(
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
                icon,
                const SizedBox(height: AppSpacing.lg),
                title,
                const SizedBox(height: AppSpacing.sm),
                subtitle,
                const SizedBox(height: AppSpacing.xl),
                scanButton,
                if (routeButton != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  routeButton,
                ],
              ],
            ),
          ),
        );
      },
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
            Text(
                'Scanning ${AppPreferences.formatDistance(AppPreferences.nearbyRadiusMeters, _distanceUnit)} radius...'),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
          child: Row(
            children: [
              ViewToggle(
                mode: _viewMode,
                onChanged: (m) async {
                  setState(() => _viewMode = m);
                  await AppPreferences.setViewMode('nearby', m);
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: _viewMode == ViewMode.map
              ? _buildResultsMapView()
              : _buildResultsList(context),
        ),
      ],
    );
  }

  Widget _buildResultsMapView() {
    if (_scanPosition == null) {
      return const Center(child: CircularProgressIndicator(color: postalRed));
    }
    final center = LatLng(_scanPosition!.latitude, _scanPosition!.longitude);
    return PostboxMap(
      center: center,
      zoom: 14,
      circleMarkers: [
        scanRadiusCircle(center,
            radiusMeters: AppPreferences.nearbyRadiusMeters),
      ],
      markers: [userPositionMarker(center)],
    );
  }

  Widget _buildResultsList(BuildContext context) {
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
            // Context map — "You Are Here" with scan radius
            if (_scanPosition != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md, AppSpacing.xs, AppSpacing.md, 0),
                child: _contextMap(_scanPosition!),
              ),

            // Summary card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.sm),
                      decoration: BoxDecoration(
                        color: postalRed.withValues(alpha: 0.1),
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
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
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
                                  ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant),
                            ),
                          if (_lastScanned != null)
                            Text(
                              'Scanned at ${TimeOfDay.fromDateTime(_lastScanned!).format(context)}',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant),
                            ),
                          if (_claimedToday > 0)
                            Row(
                              children: [
                                const Icon(Icons.lock_clock,
                                    size: 12, color: Colors.orange),
                                const SizedBox(width: 4),
                                Text(
                                  '$_claimedToday claimed today',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
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
                    Icon(Icons.location_off,
                        size: 60,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.2)),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      'No postboxes found within ${AppPreferences.formatDistance(AppPreferences.nearbyRadiusMeters, _distanceUnit)}',
                      style: Theme.of(context).textTheme.titleMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      'Try a different location.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                    if (!RemoteConfigService.instance.killSwitchReporting) ...[
                      const SizedBox(height: AppSpacing.md),
                      OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) =>
                                  const ReportMissingPostboxScreen()),
                        ),
                        icon: const Icon(Icons.report_gmailerrorred_outlined),
                        label: const Text('Report a missing postbox'),
                      ),
                    ],
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

            // Compass — shown whenever postboxes are nearby (claimed or not).
            // Red sectors = unclaimed (to find); grey sectors = already claimed today.
            if (_count > 0) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md, AppSpacing.lg, AppSpacing.md, AppSpacing.xs),
                child: Text(
                  _claimedToday < _count
                      ? 'Where to look'
                      : 'Where you\'ve been',
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
                  claimedCompassCounts: _claimedCompassCounts,
                  headingDegrees: heading,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _contextMap(Position position) {
    final center = LatLng(position.latitude, position.longitude);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 150,
        child: PostboxMap(
          center: center,
          zoom: 13,
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.none,
          ),
          circleMarkers: [
            scanRadiusCircle(
              center,
              radiusMeters: AppPreferences.nearbyRadiusMeters,
              borderColor: postalRed.withValues(alpha: 0.7),
            ),
          ],
          markers: [userPositionMarker(center)],
          bottomPadding: 0,
        ),
      ),
    );
  }

  Widget _monarchCard(
      BuildContext context, String code, int count, int claimed) {
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
          backgroundColor: color.withValues(alpha: allClaimed ? 0.06 : 0.12),
          child: Text(
            allClaimed ? '✓' : '$available',
            style: TextStyle(
              color: allClaimed
                  ? Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.38)
                  : color,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        title: Text(
          label,
          style: allClaimed
              ? TextStyle(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.38))
              : null,
        ),
        subtitle: Text(
          allClaimed
              ? '$code · claimed today'
              : claimed > 0
                  ? '$code · ${MonarchInfo.getPoints(code)} pts · $available of $count available'
                  : '$code · ${MonarchInfo.getPoints(code)} pts each',
          style: allClaimed
              ? TextStyle(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.38))
              : null,
        ),
        trailing: allClaimed ? null : trailing,
      ),
    );
  }
}
