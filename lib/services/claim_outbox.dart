// Offline claim outbox (ROADMAP v1.5, offline play Phase 3).
//
// Captures made without signal are banked here (SharedPreferences, JSON) and
// flushed by outbox_sync.dart via the flushOfflineClaims callable when the
// link returns. Each entry carries the scan token its scan issued, the
// capture position, BOTH clocks (see below), and the attemptId used for the
// server's idempotent replay.
//
// Clock anchoring: an NTP resync mid-outing can move the wall clock so two
// captures get a near-zero delta — 40 m apart that reads as 2400 m/min and
// spuriously rejects an honest user server-side. So each capture stores the
// process-monotonic elapsed too; a flush in the same process derives capture
// times from `flushWall - (monotonicNow - monotonicAtCapture)`, immune to
// wall-clock steps. Across a restart the monotonic anchor is gone and the
// stored wall clock is the best available fallback.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One banked offline capture.
class OutboxEntry {
  const OutboxEntry({
    required this.scanId,
    required this.lat,
    required this.lng,
    required this.capturedWallMs,
    required this.capturedMonotonicMs,
    required this.attemptId,
  });

  /// The HMAC scan token from the nearbyPostboxes response that authorised
  /// this capture (see functions/src/_scanToken.ts).
  final String scanId;
  final double lat;
  final double lng;

  /// Wall clock at capture (ms since epoch) — the cross-restart fallback.
  final int capturedWallMs;

  /// Process-monotonic elapsed at capture (ms) — the in-process anchor.
  final int capturedMonotonicMs;

  /// Client-generated id for the server's idempotent replay; also this
  /// entry's identity within the outbox.
  final String attemptId;

  /// The capture time to send at flush: monotonic-anchored when this process
  /// took the capture (flush monotonic ≥ capture monotonic), else the stored
  /// wall clock.
  int capturedAtForFlush({required int flushWallMs, required int flushMonotonicMs}) {
    if (flushMonotonicMs >= capturedMonotonicMs) {
      return flushWallMs - (flushMonotonicMs - capturedMonotonicMs);
    }
    return capturedWallMs;
  }

  Map<String, Object> toJson() => {
        'scanId': scanId,
        'lat': lat,
        'lng': lng,
        'capturedWallMs': capturedWallMs,
        'capturedMonotonicMs': capturedMonotonicMs,
        'attemptId': attemptId,
      };

  static OutboxEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final scanId = raw['scanId'];
    final lat = raw['lat'];
    final lng = raw['lng'];
    final wall = raw['capturedWallMs'];
    final mono = raw['capturedMonotonicMs'];
    final attemptId = raw['attemptId'];
    if (scanId is! String || attemptId is! String ||
        lat is! num || lng is! num || wall is! num || mono is! num) {
      return null;
    }
    return OutboxEntry(
      scanId: scanId,
      lat: lat.toDouble(),
      lng: lng.toDouble(),
      capturedWallMs: wall.toInt(),
      capturedMonotonicMs: mono.toInt(),
      attemptId: attemptId,
    );
  }
}

class ClaimOutbox {
  ClaimOutbox({Future<SharedPreferences> Function()? prefsProvider})
      : _prefsProvider = prefsProvider ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _prefsProvider;

  static const String storageKey = 'claim_outbox_v1';

  /// Bounded queue: far above any honest outing (the server flush batch is 20
  /// and the daily quota 30), low enough that a runaway path can't bloat
  /// prefs. Oldest entries are dropped first.
  static const int maxEntries = 50;

  static ClaimOutbox? _instance;
  static ClaimOutbox get instance => _instance ??= ClaimOutbox();

  /// Process-wide monotonic clock. Captures and flushes MUST read the same
  /// stopwatch or the anchoring maths in [OutboxEntry.capturedAtForFlush]
  /// is meaningless.
  static final Stopwatch _monotonic = Stopwatch()..start();
  static int monotonicNowMs() => _monotonic.elapsedMilliseconds;

  @visibleForTesting
  static set instance(ClaimOutbox value) => _instance = value;

  @visibleForTesting
  static void resetForTest() => _instance = null;

  /// Number of banked captures, for the OfflineBanner / badge surfaces.
  /// Loaded lazily on first [entries]/[add]; 0 until then.
  final ValueNotifier<int> pendingCount = ValueNotifier<int>(0);

  List<OutboxEntry>? _cache;

  Future<List<OutboxEntry>> _load() async {
    if (_cache != null) return _cache!;
    try {
      final prefs = await _prefsProvider();
      final raw = prefs.getString(storageKey);
      if (raw == null) {
        _cache = [];
      } else {
        final decoded = jsonDecode(raw);
        _cache = decoded is List
            ? decoded.map(OutboxEntry.fromJson).whereType<OutboxEntry>().toList()
            : <OutboxEntry>[];
      }
    } catch (_) {
      // Corrupt storage: an empty outbox beats a crash loop on every launch.
      _cache = [];
    }
    pendingCount.value = _cache!.length;
    return _cache!;
  }

  Future<void> _save() async {
    final prefs = await _prefsProvider();
    await prefs.setString(
        storageKey, jsonEncode(_cache!.map((e) => e.toJson()).toList()));
    pendingCount.value = _cache!.length;
  }

  /// The banked captures, oldest first.
  Future<List<OutboxEntry>> entries() async =>
      List.unmodifiable(await _load());

  Future<void> add(OutboxEntry entry) async {
    final list = await _load();
    list.add(entry);
    while (list.length > maxEntries) {
      list.removeAt(0);
    }
    await _save();
  }

  /// Remove settled entries (flushed OK or definitively rejected).
  Future<void> removeByAttemptIds(Set<String> attemptIds) async {
    final list = await _load();
    list.removeWhere((e) => attemptIds.contains(e.attemptId));
    await _save();
  }

  /// Drop entries older than the grace window (they can never flush
  /// successfully). Returns how many were dropped.
  Future<int> pruneExpired({required int graceHours}) async {
    final list = await _load();
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - graceHours * 3600000;
    final before = list.length;
    list.removeWhere((e) => e.capturedWallMs < cutoff);
    if (list.length != before) await _save();
    return before - list.length;
  }
}
