import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:postbox_game/firebase_functions_eu.dart';
import 'package:postbox_game/services/claim_events.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/wear/wear_labels.dart';
import 'package:postbox_game/wear/wear_round_inset.dart';
import 'package:postbox_game/wear/wear_theme.dart';

/// Signature of the `userClaimHistory` callable, injectable for tests.
///
/// Declared here rather than imported from `claim_history_screen.dart` so the
/// Wear tree never pulls in the phone history screen (and with it flutter_map).
typedef WearHistoryCallableFn = Future<HttpsCallableResult<dynamic>> Function(
    Map<String, dynamic> payload);

/// Watch-length copy for a failed history fetch. Kept separate from
/// `wearClaimErrorMessage`, whose fallback ("Claim failed") would be a lie
/// here.
String wearTodayErrorMessage(String code) => switch (code) {
      'unavailable' => 'No connection.',
      'unauthenticated' => 'Sign in again',
      _ => 'Could not load',
    };

/// One postbox claimed today.
class WearTodayClaim {
  const WearTodayClaim({required this.monarch, required this.points});

  final String? monarch;
  final int points;
}

/// Today's haul, parsed from the `userClaimHistory` response.
class WearTodaySummary {
  const WearTodaySummary({required this.claims, required this.points});

  final List<WearTodayClaim> claims;
  final int points;

  int get boxes => claims.length;
  bool get isEmpty => claims.isEmpty;
}

/// Pure parse of the `userClaimHistory` payload.
///
/// The callable returns one entry per DISTINCT postbox for the period, already
/// sorted most-recently-claimed first, each carrying the period's `totalPoints`
/// for that box — so the box count is the entry count and today's points are
/// the sum, with no client-side dedupe.
WearTodaySummary parseWearToday(dynamic data) {
  final map = data is Map ? data : const <dynamic, dynamic>{};
  final raw = map['entries'] as List<dynamic>? ?? const <dynamic>[];
  final claims = <WearTodayClaim>[];
  var points = 0;
  for (final e in raw) {
    if (e is! Map) continue;
    final p = (e['totalPoints'] is num) ? (e['totalPoints'] as num).toInt() : 0;
    points += p;
    claims.add(WearTodayClaim(monarch: e['monarch'] as String?, points: p));
  }
  return WearTodaySummary(claims: claims, points: points);
}

/// What you've claimed today, at a glance.
///
/// Calls `userClaimHistory` with `period: 'daily'` — the same callable and
/// period the phone's History tab uses, so there is no new backend surface.
///
/// Refetches whenever [ClaimEvents.revision] changes: this page stays alive
/// inside the shell's [PageView], so without that signal it would keep saying
/// "No claims today" immediately after a claim, which is the phone bug
/// `ClaimEvents` was introduced to fix. A tap forces a refresh; otherwise
/// repeat fetches are throttled, since a watch page can be swiped past
/// repeatedly and each fetch is a Firestore join.
class WearTodayPage extends StatefulWidget {
  const WearTodayPage({super.key, WearHistoryCallableFn? historyCallable})
      : _historyCallable = historyCallable;

  final WearHistoryCallableFn? _historyCallable;

  /// Minimum gap between unforced fetches.
  static const Duration refetchThrottle = Duration(seconds: 60);

  @override
  State<WearTodayPage> createState() => _WearTodayPageState();
}

class _WearTodayPageState extends State<WearTodayPage> {
  late final WearHistoryCallableFn _callable = widget._historyCallable ??
      ((payload) =>
          appFunctions.httpsCallable('userClaimHistory').call(payload));

  WearTodaySummary? _summary;
  String? _error;
  bool _loading = false;
  DateTime? _lastFetch;

  @override
  void initState() {
    super.initState();
    ClaimEvents.revision.addListener(_onClaimSettled);
    unawaited(_fetch());
  }

  @override
  void dispose() {
    ClaimEvents.revision.removeListener(_onClaimSettled);
    super.dispose();
  }

  // A claim just settled, so the throttle must not apply — this is precisely
  // the moment the page is wrong.
  void _onClaimSettled() => unawaited(_fetch(force: true));

  Future<void> _fetch({bool force = false}) async {
    if (_loading) return;
    final last = _lastFetch;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < WearTodayPage.refetchThrottle) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Read-only, so safe to retry wholesale.
      final result = await retryOnUnavailable(
          () => _callable(<String, dynamic>{'period': 'daily'}));
      if (!mounted) return;
      setState(() {
        _summary = parseWearToday(result.data);
        _lastFetch = DateTime.now();
      });
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _error = wearTodayErrorMessage(e.code));
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not load');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return WearTodayView(
      summary: _summary,
      error: _error,
      loading: _loading && _summary == null,
      onRefresh: () => unawaited(_fetch(force: true)),
    );
  }
}

/// Pure, prop-driven rendering for [WearTodayPage].
class WearTodayView extends StatelessWidget {
  const WearTodayView({
    super.key,
    required this.summary,
    required this.onRefresh,
    this.error,
    this.loading = false,
  });

  final WearTodaySummary? summary;
  final String? error;
  final bool loading;
  final VoidCallback onRefresh;

  /// How many cipher rows fit under the headline inside the inscribed square.
  static const int visibleRows = 3;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onRefresh,
      behavior: HitTestBehavior.opaque,
      child: Container(
        color: Colors.black,
        child: WearRoundInset(
          child: Center(child: _content(context)),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    if (loading) return const CircularProgressIndicator(strokeWidth: 2);

    final err = error;
    if (err != null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(err,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: WearSpacing.xs),
          Text('Tap to retry',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.6),
                  )),
        ],
      );
    }

    final s = summary;
    if (s == null || s.isEmpty) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('No claims today',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: WearSpacing.xs),
          Text('Go find a postbox',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.6),
                  )),
        ],
      );
    }

    final shown = s.claims.take(visibleRows).toList();
    final remaining = s.boxes - shown.length;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${s.boxes} ${s.boxes == 1 ? 'box' : 'boxes'} · ${s.points} pts',
          style: Theme.of(context).textTheme.titleSmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: WearSpacing.sm),
        for (var i = 0; i < shown.length; i++) ...[
          if (i > 0) const SizedBox(height: WearSpacing.xs),
          _claimRow(context, shown[i]),
        ],
        if (remaining > 0) ...[
          const SizedBox(height: WearSpacing.xs),
          Text('+$remaining more',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.6),
                  )),
        ],
      ],
    );
  }

  Widget _claimRow(BuildContext context, WearTodayClaim claim) {
    final style = Theme.of(context).textTheme.bodySmall;
    final code = claim.monarch;
    return Row(
      children: [
        Expanded(
          child: Text(
            code == null ? 'Unknown' : watchMonarchLabel(code),
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: WearSpacing.sm),
        Text('${claim.points}',
            style: style?.copyWith(
                color: postalGold, fontWeight: FontWeight.bold)),
      ],
    );
  }
}
