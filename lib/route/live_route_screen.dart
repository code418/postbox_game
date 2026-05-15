import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/app_preferences.dart';
import 'package:postbox_game/fuzzy_compass.dart';
import 'package:postbox_game/james_controller.dart';
import 'package:postbox_game/location_service.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/widgets/claim_quiz_sheet.dart';

import 'route_compass_view.dart';
import 'route_completion_screen.dart';
import 'route_session.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Generous scan radius for the fuzzy compass — shows postboxes well ahead
/// of the user to populate compass sectors. The claim trigger uses the
/// separate [AppPreferences.claimRadiusMeters] (30 m).
///
/// TODO(route): move to AppPreferences once a Settings UI exists for route mode.
const int _kFuzzyCompassScanRadiusM = 1000;

/// Minimum distance the user must move before a new scan is forced (metres).
const double _kScanDistanceTriggerM = 20.0;

/// Minimum time that must elapse before a new scan is allowed (seconds).
const int _kScanTimeTriggerS = 12;

/// Auto-arrive threshold: navigate to completion screen when the user is
/// within this many metres of the destination.
const double _kArrivalRadiusM = 25.0;

/// After the claim sheet is dismissed, suppress re-prompting for the same
/// nearby postbox for this many seconds.
const int _kClaimCooldownS = 60;

// ---------------------------------------------------------------------------
// Typedef for the nearbyPostboxes callable (injectable for testing)
// ---------------------------------------------------------------------------

/// Matches [HttpsCallable.call] so tests can stub without subclassing the
/// (sealed) [HttpsCallable].
typedef NearbyCallableFn = Future<HttpsCallableResult<dynamic>> Function(
    Map<String, dynamic> payload);

// ---------------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------------

/// Live route screen: streams GPS positions, keeps the fuzzy compass updated,
/// and presents a claim quiz sheet when the user is within range of an
/// unclaimed postbox.
///
/// Accepts [positionStreamOverride] and [nearbyCallable] for test injection.
class LiveRouteScreen extends StatefulWidget {
  final RouteSession session;

  /// Injectable GPS stream (defaults to [positionStream] from LocationService).
  final Stream<Position>? positionStreamOverride;

  /// Injectable nearbyPostboxes callable (defaults to Firebase).
  final NearbyCallableFn? nearbyCallable;

  /// Injectable compass event stream (defaults to [FlutterCompass.events]).
  /// Inject an empty stream or null in tests to skip the platform channel.
  final Stream<CompassEvent>? compassStreamOverride;

  const LiveRouteScreen({
    super.key,
    required this.session,
    this.positionStreamOverride,
    this.nearbyCallable,
    this.compassStreamOverride,
  });

  @override
  State<LiveRouteScreen> createState() => _LiveRouteScreenState();
}

class _LiveRouteScreenState extends State<LiveRouteScreen> {
  // ── GPS streaming ─────────────────────────────────────────────────────────
  StreamSubscription<Position>? _positionSub;
  StreamSubscription<CompassEvent>? _compassSub;

  // Stored so T9 can use the position for a mini-map; suppressed lint for now.
  // ignore: unused_field
  Position? _currentPosition;

  // ── Compass ────────────────────────────────────────────────────────────────
  double? _deviceHeadingDegrees;

  // ── Destination stats (recomputed on each position update) ────────────────
  double _distanceToDestM = double.infinity;
  double _bearingToDestDeg = 0.0;

  // ── Fuzzy compass data (updated after each scan) ──────────────────────────
  Map<String, int> _compassCounts = {};
  Map<String, int> _claimedCompassCounts = {};

  // ── Scan throttle ─────────────────────────────────────────────────────────
  DateTime? _lastScanAt;
  Position? _lastScanPos;
  bool _scanInFlight = false;

  // ── Claim sheet state ─────────────────────────────────────────────────────
  bool _claimSheetOpen = false;

  /// Postbox IDs dismissed within the last [_kClaimCooldownS] seconds.
  /// Maps postbox ID → dismissal time.
  final Map<String, DateTime> _recentDismissals = {};

  // ── Accumulated route totals ───────────────────────────────────────────────
  int _pointsEarned = 0;
  int _claimedCount = 0;

  // ── Session timer ─────────────────────────────────────────────────────────
  late final Stopwatch _stopwatch = Stopwatch()..start();

  // ── Arrived? ──────────────────────────────────────────────────────────────
  bool _arrived = false;

  // ── Callable ──────────────────────────────────────────────────────────────
  late final NearbyCallableFn _nearby;

  @override
  void initState() {
    super.initState();

    _nearby = widget.nearbyCallable ??
        (Map<String, dynamic> payload) =>
            FirebaseFunctions.instance
                .httpsCallable('nearbyPostboxes')
                .call(payload);

    // Subscribe to the device compass for heading.
    // Use the injected stream (if any) — otherwise fall back to FlutterCompass.
    // Wrapped in try-catch: FlutterCompass.events is non-null but will throw a
    // MissingPluginException in test environments without the platform channel.
    final compassStream = widget.compassStreamOverride ?? FlutterCompass.events;
    try {
      _compassSub = compassStream?.listen((CompassEvent e) {
        final h = e.heading;
        if (h == null) return;
        final prev = _deviceHeadingDegrees;
        // Throttle updates to changes >= 5° to avoid excessive rebuilds.
        if (prev == null || _headingDelta(prev, h) >= 5) {
          if (mounted) setState(() => _deviceHeadingDegrees = h);
        }
      });
    } catch (_) {
      // Compass not available on this platform/environment.
      _compassSub = null;
    }

    // Subscribe to the GPS position stream.
    final stream = widget.positionStreamOverride ??
        positionStream(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilterMetres: 5,
        );
    _positionSub = stream.listen(
      _onPosition,
      onError: _onPositionError,
    );
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _compassSub?.cancel();
    _stopwatch.stop();
    super.dispose();
  }

  // ── Heading helper ────────────────────────────────────────────────────────

  static double _headingDelta(double a, double b) {
    final d = (a - b).abs() % 360;
    return d > 180 ? 360 - d : d;
  }

  // ── Position handler ──────────────────────────────────────────────────────

  void _onPosition(Position pos) {
    if (!mounted) return;

    final dest = widget.session.destination;
    final dist = Geolocator.distanceBetween(
      pos.latitude, pos.longitude,
      dest.latitude, dest.longitude,
    );
    final rawBearing = Geolocator.bearingBetween(
      pos.latitude, pos.longitude,
      dest.latitude, dest.longitude,
    );
    // Normalise to 0..360.
    final bearing = rawBearing < 0 ? rawBearing + 360 : rawBearing;

    setState(() {
      _currentPosition = pos;
      _distanceToDestM = dist;
      _bearingToDestDeg = bearing;
    });

    // Arrival detection — only navigate once.
    if (!_arrived && dist < _kArrivalRadiusM) {
      _arrived = true;
      _navigateToCompletion();
      return;
    }

    _maybeScan(pos);
  }

  void _onPositionError(Object error) {
    if (!mounted) return;
    debugPrint('LiveRouteScreen position error: $error');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Location error. Check GPS permissions.'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }

  // ── Scan logic ────────────────────────────────────────────────────────────

  Future<void> _maybeScan(Position pos) async {
    if (_scanInFlight) return;

    final now = DateTime.now();
    final timeSinceLast = _lastScanAt == null
        ? const Duration(days: 1) // Always scan on first call.
        : now.difference(_lastScanAt!);
    final distSinceLast = _lastScanPos == null
        ? double.infinity
        : Geolocator.distanceBetween(
            pos.latitude, pos.longitude,
            _lastScanPos!.latitude, _lastScanPos!.longitude,
          );

    final timeTriggered = timeSinceLast.inSeconds >= _kScanTimeTriggerS;
    final distTriggered = distSinceLast >= _kScanDistanceTriggerM;
    if (!timeTriggered && !distTriggered) return;

    _scanInFlight = true;
    _lastScanAt = now;
    _lastScanPos = pos;

    try {
      final result = await _nearby({
        'lat': pos.latitude,
        'lng': pos.longitude,
        'meters': _kFuzzyCompassScanRadiusM,
      });
      if (!mounted) return;

      final data = Map<String, dynamic>.from(result.data as Map);
      final compass = data['compass'] != null
          ? Map<String, dynamic>.from(data['compass'] as Map)
          : <String, dynamic>{};
      final claimedCompass = data['claimedCompass'] != null
          ? Map<String, dynamic>.from(data['claimedCompass'] as Map)
          : <String, dynamic>{};

      int asInt(dynamic v) => (v as num?)?.toInt() ?? 0;

      final newCounts = <String, int>{};
      final newClaimed = <String, int>{};
      for (final dir in const [
        'N', 'NNE', 'NE', 'ENE', 'E', 'ESE',
        'SE', 'SSE', 'S', 'SSW', 'SW', 'WSW',
        'W', 'WNW', 'NW', 'NNW',
      ]) {
        newCounts[dir] = asInt(compass[dir]);
        newClaimed[dir] = asInt(claimedCompass[dir]);
      }

      if (mounted) {
        setState(() {
          _compassCounts = newCounts;
          _claimedCompassCounts = newClaimed;
        });
      }

      // Check for claimable postboxes within 30 m.
      _checkForNearbyClaimable(data, pos);
    } catch (e) {
      debugPrint('LiveRouteScreen scan error: $e');
      // Non-fatal: skip this scan cycle and try next time.
    } finally {
      _scanInFlight = false;
    }
  }

  void _checkForNearbyClaimable(Map<String, dynamic> data, Position pos) {
    if (_claimSheetOpen) return;

    final rawPostboxes = data['postboxes'] as Map? ?? {};
    final now = DateTime.now();

    // Purge expired cooldowns.
    _recentDismissals.removeWhere(
      (_, t) => now.difference(t).inSeconds > _kClaimCooldownS,
    );

    String? eligibleId;
    for (final entry in rawPostboxes.entries) {
      final id = entry.key as String;
      final box = Map<String, dynamic>.from(entry.value as Map);
      final claimedToday = box['claimedToday'] == true;
      final rawDist = box['distance'];
      final dist = rawDist is num ? rawDist.toDouble() : double.infinity;

      if (claimedToday) continue;
      if (dist > AppPreferences.claimRadiusMeters) continue;
      if (_recentDismissals.containsKey(id)) continue;

      eligibleId = id;
      break;
    }

    if (eligibleId == null) return;
    _openClaimSheet(LatLng(pos.latitude, pos.longitude), eligibleId);
  }

  void _openClaimSheet(LatLng scanPos, String postboxId) {
    if (_claimSheetOpen) return;
    _claimSheetOpen = true;

    showModalBottomSheet<ClaimQuizResult>(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        expand: false,
        builder: (_, scrollController) => ClaimQuizSheet(
          scanPosition: scanPos,
          compact: true,
          onCompleted: (result) {
            Navigator.of(context).pop(result);
          },
        ),
      ),
    ).then((result) {
      _claimSheetOpen = false;
      // Record dismissal to suppress re-prompting for this box.
      _recentDismissals[postboxId] = DateTime.now();

      if (result != null && result.claimedCount > 0) {
        if (mounted) {
          setState(() {
            _pointsEarned += result.pointsEarned;
            _claimedCount += result.claimedCount;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                result.claimedCount > 1
                    ? '${result.claimedCount} postboxes claimed! +${result.pointsEarned} pts'
                    : 'Postbox claimed! +${result.pointsEarned} pts',
              ),
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    });
  }

  // ── Arrival ────────────────────────────────────────────────────────────────

  void _navigateToCompletion() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => RouteCompletionScreen(
          session: widget.session,
          pointsEarned: _pointsEarned,
          claimedCount: _claimedCount,
          walkSeconds: _stopwatch.elapsed.inSeconds,
        ),
      ),
    );
  }

  // ── Abandon confirmation ───────────────────────────────────────────────────

  Future<bool> _confirmAbandon() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End route now?'),
        content: const Text('Points already claimed will keep.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep going'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('End route'),
          ),
        ],
      ),
    );
    return result == true;
  }

  // ── Hint logic ─────────────────────────────────────────────────────────────

  /// Returns one of {"ahead", "left", "right", "behind"} relative to the
  /// destination bearing, based on which 8-wind sector has the most unclaimed
  /// postboxes in the last fuzzy compass scan.
  String _pickHintDirection() {
    final sectors8 = FuzzyCompass.to8Sectors(_compassCounts);
    const order = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    String bestDir = 'N';
    int bestCount = -1;
    for (final dir in order) {
      final c = sectors8[dir] ?? 0;
      if (c > bestCount) {
        bestCount = c;
        bestDir = dir;
      }
    }
    if (bestCount <= 0) return 'ahead'; // Nothing visible — default.

    const dirBearings = {
      'N': 0.0, 'NE': 45.0, 'E': 90.0, 'SE': 135.0,
      'S': 180.0, 'SW': 225.0, 'W': 270.0, 'NW': 315.0,
    };
    final sectorBearing = dirBearings[bestDir] ?? 0.0;

    // Relative angle between the best sector and the destination bearing.
    // Positive = clockwise (right), negative = anticlockwise (left).
    double rel = (sectorBearing - _bearingToDestDeg) % 360;
    if (rel > 180) rel -= 360; // Normalise to -180..180.

    if (rel.abs() <= 45) return 'ahead';
    if (rel > 45 && rel <= 135) return 'right';
    if (rel < -45 && rel >= -135) return 'left';
    return 'behind';
  }

  void _onHintTapped() {
    final direction = _pickHintDirection();
    // T10 will swap in a proper JamesMessages pool for route mode.
    JamesController.of(context)?.show('Try heading $direction.');
  }

  // ── ETA helper ─────────────────────────────────────────────────────────────

  String _etaLabel() {
    if (_distanceToDestM.isInfinite || _distanceToDestM.isNaN) return '...';
    final speedKmh = widget.session.speedKmh;
    final distKm = _distanceToDestM / 1000.0;
    final minutes = (distKm / speedKmh * 60).round();
    final paceLabel =
        widget.session.pace == RoutePace.jog ? 'jogging' : 'walking';
    return '≈ $minutes min $paceLabel';
  }

  // ── Bearing label ──────────────────────────────────────────────────────────

  static String _bearingLabel(double deg) {
    const labels = [
      'N', 'NNE', 'NE', 'ENE',
      'E', 'ESE', 'SE', 'SSE',
      'S', 'SSW', 'SW', 'WSW',
      'W', 'WNW', 'NW', 'NNW',
    ];
    final idx = ((deg + 11.25) / 22.5).floor() % 16;
    return labels[idx];
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final abandon = await _confirmAbandon();
        if (abandon && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Route'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'End route',
            onPressed: () async {
              final abandon = await _confirmAbandon();
              if (abandon && context.mounted) {
                Navigator.of(context).pop();
              }
            },
          ),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.only(bottom: kJamesStripClearance),
            children: [
              // ── a. Destination card ─────────────────────────────────────
              _DestinationCard(
                distanceM: _distanceToDestM,
                bearingLabel: _bearingLabel(_bearingToDestDeg),
                etaLabel: _etaLabel(),
                destinationLabel: widget.session.destinationLabel,
              ),

              // ── b. Route compass view ───────────────────────────────────
              RouteCompassView(
                compassCounts: _compassCounts,
                claimedCompassCounts: _claimedCompassCounts,
                deviceHeadingDegrees: _deviceHeadingDegrees,
                destinationBearingDegrees: _bearingToDestDeg,
              ),

              // ── c. Hint button ──────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                child: FilledButton.tonal(
                  onPressed: _onHintTapped,
                  child: const Text('Where now, postie?'),
                ),
              ),

              // ── d. Status row ───────────────────────────────────────────
              _StatusRow(
                pointsEarned: _pointsEarned,
                claimedCount: _claimedCount,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _DestinationCard extends StatelessWidget {
  final double distanceM;
  final String bearingLabel;
  final String etaLabel;
  final String? destinationLabel;

  const _DestinationCard({
    required this.distanceM,
    required this.bearingLabel,
    required this.etaLabel,
    this.destinationLabel,
  });

  String get _distanceText {
    if (distanceM == double.infinity) return '...';
    if (distanceM < 1000) {
      return '${distanceM.round()} m';
    }
    return '${(distanceM / 1000).toStringAsFixed(2)} km';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (destinationLabel != null) ...[
              Text(
                destinationLabel!,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppSpacing.xs),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  _distanceText,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Chip(
                  label: Text(bearingLabel),
                  avatar: const Icon(Icons.navigation, size: 14),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              etaLabel,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final int pointsEarned;
  final int claimedCount;

  const _StatusRow({
    required this.pointsEarned,
    required this.claimedCount,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        children: [
          Chip(
            avatar: const Icon(Icons.star, size: 14, color: postalGold),
            label: Text(
              pointsEarned == 0 ? '0 pts' : '+$pointsEarned pts',
            ),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: AppSpacing.sm),
          Chip(
            avatar: const Icon(Icons.markunread_mailbox_outlined, size: 14),
            label: Text(
              '$claimedCount claimed',
            ),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
