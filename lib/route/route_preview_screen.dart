import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:postbox_game/route/live_route_screen.dart';
import 'package:postbox_game/route/route_session.dart';
import 'package:postbox_game/theme.dart';

// ---------------------------------------------------------------------------
// Callable function type
// ---------------------------------------------------------------------------

/// Function signature for calling a Firebase HTTPS callable.
///
/// Matches the signature of [HttpsCallable.call] so that tests can inject a
/// stub without needing to subclass the (sealed) [HttpsCallable].
typedef RouteCallableFn = Future<HttpsCallableResult<dynamic>> Function(
    Map<String, dynamic> payload);

// ---------------------------------------------------------------------------
// State helpers
// ---------------------------------------------------------------------------

enum _HeadlineState { idle, loading, result, error }

// ---------------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------------

/// Lets the user tune pace, corridor width, and detour budget before starting
/// a route. Debounces calls to the `routePostboxes` Cloud Function and shows
/// the resulting postbox count and points estimate.
///
/// [callableFn] can be injected in tests to bypass the real Firebase function.
class RoutePreviewScreen extends StatefulWidget {
  final RouteSession session;

  /// Injectable for testing — defaults to the real `routePostboxes` callable.
  final RouteCallableFn? callableFn;

  const RoutePreviewScreen({
    super.key,
    required this.session,
    this.callableFn,
  });

  @override
  State<RoutePreviewScreen> createState() => _RoutePreviewScreenState();
}

class _RoutePreviewScreenState extends State<RoutePreviewScreen> {
  // ── Callable ───────────────────────────────────────────────────────────────
  late final RouteCallableFn _callableFn;

  // ── Debounce ───────────────────────────────────────────────────────────────
  Timer? _debounceTimer;

  /// Incremented on every debounced trigger; checked after `await` to discard
  /// stale responses.
  int _requestId = 0;

  // ── UI state ───────────────────────────────────────────────────────────────
  _HeadlineState _headlineState = _HeadlineState.idle;

  /// The most recent error message (non-null when [_headlineState] is error).
  String? _errorMessage;

  /// Cached `directDistanceM` from the last successful response.
  num? _directDistanceM;

  /// True once at least one successful response has been received.
  bool _hasResult = false;

  @override
  void initState() {
    super.initState();
    _callableFn = widget.callableFn ??
        (payload) => FirebaseFunctions.instance
            .httpsCallable('routePostboxes')
            .call(payload);
    // Fire the initial call immediately.
    _scheduleFetch(immediate: true);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }

  // ── Debounce / fetch ────────────────────────────────────────────────────────

  void _scheduleFetch({bool immediate = false}) {
    _debounceTimer?.cancel();
    // Flip to loading right now (not after the debounce) so the headline and
    // the Start-route button reflect that the displayed result no longer
    // matches the current session params. Without this, a user could tap
    // Start within the 400 ms debounce window and begin a route whose stats
    // banner shows the previous params' count/points.
    if (!immediate && _headlineState != _HeadlineState.loading) {
      setState(() {
        _headlineState = _HeadlineState.loading;
        _errorMessage = null;
      });
    }
    _debounceTimer = Timer(
      immediate ? Duration.zero : const Duration(milliseconds: 400),
      _fetch,
    );
  }

  Future<void> _fetch() async {
    if (!mounted) return;

    final id = ++_requestId;

    setState(() {
      _headlineState = _HeadlineState.loading;
      _errorMessage = null;
    });

    final session = widget.session;

    final Map<String, dynamic> payload = {
      'startLat': session.start.latitude,
      'startLng': session.start.longitude,
      'destLat': session.destination.latitude,
      'destLng': session.destination.longitude,
      'mode': session.mode == RouteMode.detour ? 'detour' : 'corridor',
      'speedKmh': session.speedKmh,
    };

    if (session.mode == RouteMode.corridor) {
      payload['corridorMetres'] = session.corridorMetres;
    } else {
      payload['detourMinutes'] = session.detourMinutes;
    }

    try {
      final result = await _callableFn(payload);
      if (!mounted || _requestId != id) return;

      final data = result.data as Map<dynamic, dynamic>;
      final count = (data['count'] as num).toInt();
      final points = (data['points'] as num).toInt();
      final directDistanceM = data['directDistanceM'] as num;

      session.computedCount = count;
      session.computedPoints = points;
      session.directDistanceM = directDistanceM;

      setState(() {
        _directDistanceM = directDistanceM;
        _headlineState = _HeadlineState.result;
        _hasResult = true;
      });
    } on FirebaseFunctionsException catch (e) {
      if (!mounted || _requestId != id) return;
      final msg = _mapFunctionsError(e);
      setState(() {
        _headlineState = _HeadlineState.error;
        _errorMessage = msg;
      });
    } catch (e) {
      if (!mounted || _requestId != id) return;
      setState(() {
        _headlineState = _HeadlineState.error;
        _errorMessage = "Couldn't reach the server. Try again.";
      });
    }
  }

  String _mapFunctionsError(FirebaseFunctionsException e) {
    switch (e.code) {
      case 'unauthenticated':
        return 'Please sign in again.';
      case 'invalid-argument':
        if (e.message != null && e.message!.contains('30 km')) {
          return 'Destination is too far for a route (30 km limit).';
        }
        return e.message ?? 'Invalid request.';
      default:
        return "Couldn't reach the server. Try again.";
    }
  }

  // ── Pace change ─────────────────────────────────────────────────────────────

  void _onPaceChanged(RoutePace pace) {
    setState(() => widget.session.pace = pace);
    _scheduleFetch();
  }

  // ── Corridor slider ──────────────────────────────────────────────────────────

  void _onCorridorChanged(double value) {
    setState(() {
      widget.session.corridorMetres = value.round();
      // Corridor slider is only shown when detour == 0, so mode is already corridor.
      widget.session.mode = RouteMode.corridor;
    });
    _scheduleFetch();
  }

  // ── Detour slider ─────────────────────────────────────────────────────────

  void _onDetourChanged(double value) {
    final minutes = value.round();
    setState(() {
      widget.session.detourMinutes = minutes;
      widget.session.mode = minutes > 0 ? RouteMode.detour : RouteMode.corridor;
    });
    _scheduleFetch();
  }

  // ── Time estimate ────────────────────────────────────────────────────────

  String _timeEstimate() {
    final distM = _directDistanceM;
    if (distM == null) return '–';
    final speedMps = widget.session.speedKmh * 1000 / 3600;
    final minutes = (distM / speedMps / 60).round();
    final label =
        widget.session.pace == RoutePace.jog ? 'jogging' : 'walking';
    return '≈ $minutes min $label';
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Route preview')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          children: [
            // ── 1. Destination card ────────────────────────────────────────
            _DestinationCard(
              label: session.destinationLabel ??
                  '${session.destination.latitude.toStringAsFixed(4)}, '
                      '${session.destination.longitude.toStringAsFixed(4)}',
              directDistanceM: _directDistanceM,
            ),

            const SizedBox(height: AppSpacing.sm),

            // ── 2. Pace segmented button ──────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: SegmentedButton<RoutePace>(
                segments: const [
                  ButtonSegment(
                    value: RoutePace.walk,
                    label: Text('Walk'),
                    icon: Icon(Icons.directions_walk),
                  ),
                  ButtonSegment(
                    value: RoutePace.jog,
                    label: Text('Jog'),
                    icon: Icon(Icons.directions_run),
                  ),
                ],
                selected: {session.pace},
                onSelectionChanged: (s) => _onPaceChanged(s.first),
              ),
            ),

            // ── 3. Time estimate ──────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: Text(
                _timeEstimate(),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
              ),
            ),

            // ── 4. Corridor slider ────────────────────────────────────────
            _SliderSection(
              label:
                  'Corridor width: ${session.corridorMetres} m',
              value: session.corridorMetres.toDouble(),
              min: 50,
              max: 500,
              divisions: 9,
              onChanged: _onCorridorChanged,
            ),

            // ── 5. Detour slider ──────────────────────────────────────────
            _SliderSection(
              label:
                  'Extra time for detours: ${session.detourMinutes} min',
              value: session.detourMinutes.toDouble(),
              min: 0,
              max: 60,
              divisions: 12,
              onChanged: _onDetourChanged,
            ),

            const SizedBox(height: AppSpacing.sm),

            // ── 6. Headline ────────────────────────────────────────────────
            _HeadlineCard(
              state: _headlineState,
              count: session.computedCount,
              points: session.computedPoints,
              errorMessage: _errorMessage,
              onRetry: _fetch,
            ),

            const SizedBox(height: AppSpacing.md),

            // ── 7. Start route button ─────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: FilledButton(
                onPressed: (_headlineState == _HeadlineState.loading ||
                        _headlineState == _HeadlineState.error ||
                        !_hasResult)
                    ? null
                    : () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                LiveRouteScreen(session: session),
                          ),
                        );
                      },
                child: const Text('Start route'),
              ),
            ),

            const SizedBox(height: AppSpacing.md),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Destination card
// ---------------------------------------------------------------------------

class _DestinationCard extends StatelessWidget {
  final String label;
  final num? directDistanceM;

  const _DestinationCard({
    required this.label,
    required this.directDistanceM,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final distLabel = directDistanceM != null
        ? '${(directDistanceM! / 1000).toStringAsFixed(2)} km'
        : '–';

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(Icons.flag, color: postalRed, size: 20),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: Theme.of(context).textTheme.bodyMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    distLabel,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Slider section
// ---------------------------------------------------------------------------

class _SliderSection extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  const _SliderSection({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: value.round().toString(),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Headline card
// ---------------------------------------------------------------------------

class _HeadlineCard extends StatelessWidget {
  final _HeadlineState state;
  final int? count;
  final int? points;
  final String? errorMessage;
  final VoidCallback onRetry;

  const _HeadlineCard({
    required this.state,
    required this.count,
    required this.points,
    required this.errorMessage,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: _buildContent(context),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    switch (state) {
      case _HeadlineState.idle:
        return const SizedBox.shrink();

      case _HeadlineState.loading:
        return const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: postalRed),
            SizedBox(height: AppSpacing.sm),
            Text('Calculating...'),
          ],
        );

      case _HeadlineState.result:
        final c = count ?? 0;
        final p = points ?? 0;
        if (c == 0) {
          return Text(
            'Nothing along this route just yet… try widening the corridor or adding detour minutes.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
            textAlign: TextAlign.center,
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                style: Theme.of(context).textTheme.titleLarge,
                children: [
                  TextSpan(
                    text: '$c',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: postalRed,
                    ),
                  ),
                  const TextSpan(text: ' unclaimed postboxes en-route'),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                style: Theme.of(context).textTheme.bodyLarge,
                children: [
                  const TextSpan(text: 'worth '),
                  TextSpan(
                    text: '$p',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: postalGold,
                    ),
                  ),
                  const TextSpan(text: ' points'),
                ],
              ),
            ),
          ],
        );

      case _HeadlineState.error:
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              color: postalRed,
              size: 22,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    errorMessage ?? 'Something went wrong.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextButton(
                    onPressed: onRetry,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ],
        );
    }
  }
}
