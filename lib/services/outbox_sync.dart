// Outbox flush orchestration (ROADMAP v1.5, offline play Phase 3).
//
// Sends banked captures to the flushOfflineClaims callable and reconciles the
// per-item verdicts honestly: claimed or permanently-rejected entries leave
// the outbox; transient outcomes (transport failure, today's quota already
// spent) stay banked. Triggered by connectivity restoration (see start()),
// app-resume, and the OfflineBanner's "Send now".

import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import 'package:postbox_game/firebase_functions_eu.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/services/claim_outbox.dart';
import 'package:postbox_game/services/connectivity_service.dart';

typedef FlushCallable = Future<HttpsCallableResult<dynamic>>
    Function(Map<String, dynamic> payload);

/// What one flush attempt achieved, for UI/James reconciliation.
class FlushSummary {
  const FlushSummary({
    required this.claimed,
    required this.points,
    required this.rejected,
    required this.kept,
  });

  /// Postboxes credited by this flush.
  final int claimed;

  /// Points earned by this flush.
  final int points;

  /// Captures permanently rejected (expired, too far, too fast...). Gone.
  final int rejected;

  /// Captures still banked (e.g. today's quota spent) — will retry.
  final int kept;
}

class OutboxSync {
  OutboxSync({
    ClaimOutbox? outbox,
    FlushCallable? callable,
    int Function()? graceHoursProvider,
    int maxAutoRetries = 2,
  })  : _outbox = outbox ?? ClaimOutbox.instance,
        _callable = callable ??
            ((payload) =>
                appFunctions.httpsCallable('flushOfflineClaims').call(payload)),
        _graceHours = graceHoursProvider ??
            (() => RemoteConfigService.instance.offlineClaimGraceHours),
        _maxAutoRetries = maxAutoRetries;

  final ClaimOutbox _outbox;
  final FlushCallable _callable;
  final int Function() _graceHours;
  final int _maxAutoRetries;
  bool _flushing = false;
  VoidCallback? _connectivityListener;

  static OutboxSync? _instance;
  static OutboxSync get instance => _instance ??= OutboxSync();

  @visibleForTesting
  static set instance(OutboxSync value) => _instance = value;

  @visibleForTesting
  static void resetForTest() {
    _instance?._stopListening();
    _instance = null;
  }

  /// Verdicts that can never succeed on a retry — their entries are removed.
  /// `quota_exceeded` is deliberately absent (tomorrow is another day), as is
  /// `error` (transient server fault).
  static const Set<String> permanentReasons = {
    'bad_token',
    'before_scan',
    'future_capture',
    'expired',
    'too_far_from_scan',
    'non_monotonic',
    'too_fast',
  };

  /// Fired with each flush outcome so UI surfaces (James, snackbars) can
  /// react without polling.
  final ValueNotifier<FlushSummary?> lastSummary =
      ValueNotifier<FlushSummary?>(null);

  /// Auto-flush whenever connectivity returns. Idempotent.
  void start() {
    _stopListening();
    final online = ConnectivityService.instance.online;
    var wasOnline = online.value;
    _connectivityListener = () {
      final isOnline = online.value;
      if (isOnline && !wasOnline) unawaited(flushNow());
      wasOnline = isOnline;
    };
    online.addListener(_connectivityListener!);
  }

  void _stopListening() {
    final l = _connectivityListener;
    if (l != null) {
      ConnectivityService.instance.online.removeListener(l);
      _connectivityListener = null;
    }
  }

  /// Flush the banked captures (oldest first, one server batch). Returns the
  /// summary, or null when there was nothing to do or the link failed —
  /// entries stay banked in that case. Re-entrant calls no-op.
  Future<FlushSummary?> flushNow() async {
    if (_flushing) return null;
    _flushing = true;
    try {
      await _outbox.pruneExpired(graceHours: _graceHours());
      final entries = await _outbox.entries();
      if (entries.isEmpty) return null;

      final nowWall = DateTime.now().millisecondsSinceEpoch;
      final nowMono = ClaimOutbox.monotonicNowMs();
      final batch = entries.take(20).toList();
      // One id per logical flush attempt. A retry after a DROPPED RESPONSE
      // reuses it, so the server's attempts envelope replays the stored
      // response instead of re-adjudicating (and double-spending quota).
      //
      // It must NOT survive a response we actually received: entries kept
      // banked on purpose (`quota_exceeded` — tomorrow is another day) would
      // otherwise replay that same verdict for the envelope's 48 h TTL, which
      // outlives the 36 h grace window, so they could never be claimed. The id
      // is therefore cleared the moment a response lands, below.
      final attemptId =
          await _outbox.pendingFlushAttemptId() ?? newAttemptId();
      await _outbox.setPendingFlushAttemptId(attemptId);
      final payload = <String, dynamic>{
        'flushClientTsMs': nowWall,
        'attemptId': attemptId,
        'claims': [
          for (final e in batch)
            {
              'scanId': e.scanId,
              'lat': e.lat,
              'lng': e.lng,
              'capturedAtMs': e.capturedAtForFlush(
                  flushWallMs: nowWall, flushMonotonicMs: nowMono),
            },
        ],
      };

      final HttpsCallableResult<dynamic> result;
      try {
        result = await retryOnUnavailable(
          () => _callable(payload),
          maxRetries: _maxAutoRetries,
        );
      } on FirebaseFunctionsException {
        return null; // transport/server refusal: keep everything banked
      } catch (_) {
        return null;
      }
      // The server answered, so this logical attempt is settled: the next
      // flush must be adjudicated afresh, not replayed.
      await _outbox.setPendingFlushAttemptId(null);

      final data = Map<String, dynamic>.from(result.data as Map);
      final results = (data['results'] as List? ?? const [])
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();

      var claimed = 0;
      var points = 0;
      var rejected = 0;
      final settled = <String>{};
      for (var i = 0; i < results.length && i < batch.length; i++) {
        final r = results[i];
        if (r['ok'] == true) {
          settled.add(batch[i].attemptId);
          claimed += (r['claimed'] as num?)?.toInt() ?? 0;
          points += (r['points'] as num?)?.toInt() ?? 0;
        } else if (permanentReasons.contains(r['reason'])) {
          settled.add(batch[i].attemptId);
          rejected++;
        }
      }
      await _outbox.removeByAttemptIds(settled);
      final summary = FlushSummary(
        claimed: claimed,
        points: points,
        rejected: rejected,
        kept: (await _outbox.entries()).length,
      );
      lastSummary.value = summary;
      return summary;
    } finally {
      _flushing = false;
    }
  }
}
