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
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A collision-safe id for one logical claim (or flush) attempt, 32 hex chars.
/// Kept across transport retries so the server replays the stored response
/// instead of re-adjudicating (functions/src/_attempts.ts).
String newAttemptId() {
  final rnd = Random.secure();
  return List<int>.generate(16, (_) => rnd.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

/// One banked offline capture.
class OutboxEntry {
  const OutboxEntry({
    required this.scanId,
    required this.lat,
    required this.lng,
    required this.capturedWallMs,
    required this.capturedMonotonicMs,
    required this.attemptId,
    this.uid,
  });

  /// Who banked this capture. The outbox is device-global but its contents are
  /// user-bound (the scan token embeds the uid), so a flush by a DIFFERENT
  /// account would come back `bad_token` — a permanent reason, which would
  /// silently delete the original user's captures. [ClaimOutbox.entries] hides
  /// entries belonging to anyone but the current user for that reason.
  ///
  /// Null on entries written before this field existed; those stay visible to
  /// everyone (nothing better is knowable) and age out within the grace window.
  final String? uid;

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

  /// A copy stamped with its owning account (see [uid]).
  OutboxEntry ownedBy(String? owner) => OutboxEntry(
        scanId: scanId,
        lat: lat,
        lng: lng,
        capturedWallMs: capturedWallMs,
        capturedMonotonicMs: capturedMonotonicMs,
        attemptId: attemptId,
        uid: owner,
      );

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
        if (uid != null) 'uid': uid!,
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
    final uid = raw['uid'];
    return OutboxEntry(
      scanId: scanId,
      lat: lat.toDouble(),
      lng: lng.toDouble(),
      capturedWallMs: wall.toInt(),
      capturedMonotonicMs: mono.toInt(),
      attemptId: attemptId,
      uid: uid is String ? uid : null,
    );
  }
}

class ClaimOutbox {
  ClaimOutbox({
    Future<SharedPreferences> Function()? prefsProvider,
    String? Function()? uidProvider,
  })  : _prefsProvider = prefsProvider ?? SharedPreferences.getInstance,
        _uidProvider = uidProvider ?? currentUid;

  final Future<SharedPreferences> Function() _prefsProvider;
  final String? Function() _uidProvider;

  /// The signed-in uid, or null when signed out (or Firebase is unavailable,
  /// as in a headless test) — in which case only legacy unowned entries show.
  static String? currentUid() {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      return null;
    }
  }

  static const String storageKey = 'claim_outbox_v1';

  /// Where [pendingFlushAttemptId] is persisted. Separate from [storageKey] so
  /// it survives outbox mutations (and a process restart) independently.
  static const String flushAttemptKey = 'claim_outbox_flush_attempt_v1';

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

  /// Number of the CURRENT USER's banked captures, for the OfflineBanner /
  /// badge surfaces. Loaded lazily on first [entries]/[add]; 0 until then.
  /// Call [refreshOwnership] when the signed-in user changes.
  final ValueNotifier<int> pendingCount = ValueNotifier<int>(0);

  List<OutboxEntry>? _cache;

  /// Entries the current user may flush: their own, plus legacy entries
  /// written before [OutboxEntry.uid] existed.
  List<OutboxEntry> _owned(List<OutboxEntry> all) {
    final uid = _uidProvider();
    return all.where((e) => e.uid == null || e.uid == uid).toList();
  }

  /// Recompute [pendingCount] against the signed-in user. Call on sign-in and
  /// sign-out: the outbox is device-global but its contents are user-bound, so
  /// the count is meaningless until the owner is known.
  Future<void> refreshOwnership() async {
    pendingCount.value = _owned(await _load()).length;
  }

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
    pendingCount.value = _owned(_cache!).length;
    return _cache!;
  }

  Future<void> _save() async {
    final prefs = await _prefsProvider();
    await prefs.setString(
        storageKey, jsonEncode(_cache!.map((e) => e.toJson()).toList()));
    pendingCount.value = _owned(_cache!).length;
  }

  /// The current user's banked captures, oldest first. Another account's
  /// entries stay on disk (and stay theirs) but are never returned here — see
  /// [OutboxEntry.uid].
  Future<List<OutboxEntry>> entries() async =>
      List.unmodifiable(_owned(await _load()));

  /// Bank a capture for the signed-in user. The owner is stamped here rather
  /// than at the call site so no caller can forget it.
  Future<void> add(OutboxEntry entry) async {
    final list = await _load();
    list.add(entry.uid == null ? entry.ownedBy(_uidProvider()) : entry);
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

  /// The attemptId of a flush whose response never arrived (transport
  /// failure), so the next flush can replay it via the server's attempts
  /// envelope instead of re-adjudicating and double-spending quota. Cleared
  /// as soon as a response IS received — see [OutboxSync.flushNow].
  ///
  /// Persisted rather than held in memory so a flush interrupted by the app
  /// being killed still replays on next launch.
  Future<String?> pendingFlushAttemptId() async {
    try {
      final prefs = await _prefsProvider();
      return prefs.getString(flushAttemptKey);
    } catch (_) {
      return null; // unreadable storage: a fresh id is the safe fallback
    }
  }

  Future<void> setPendingFlushAttemptId(String? id) async {
    try {
      final prefs = await _prefsProvider();
      if (id == null) {
        await prefs.remove(flushAttemptKey);
      } else {
        await prefs.setString(flushAttemptKey, id);
      }
    } catch (_) {
      // Best effort: losing the marker costs at most one re-adjudication.
    }
  }

  /// Wipe every banked capture and any pending flush id, for ALL accounts.
  ///
  /// For account deletion only — NOT sign-out, where entries must survive so
  /// the same user can flush them after signing back in (see [OutboxEntry.uid]).
  /// A deleted account's captures can never settle, and they hold the GPS
  /// positions and timestamps of someone who has just asked to be erased;
  /// leaving them on disk to age out of the grace window is the wrong answer to
  /// that request.
  Future<void> clearAll() async {
    _cache = [];
    await _save();
    await setPendingFlushAttemptId(null);
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
