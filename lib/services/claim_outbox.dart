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
// wall-clock steps. The stopwatch resets on restart, so each capture is also
// stamped with a per-process boot id (see [ClaimOutbox.bootId]); the anchor is
// used only when the flushing process's boot id matches, otherwise the stored
// wall clock is the fallback.

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
    this.capturedBootId,
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

  /// A random id unique to the OS process that took this capture (stamped by
  /// [ClaimOutbox.add]). [capturedMonotonicMs] is only comparable to a flush's
  /// monotonic clock WITHIN that same process — a restart resets the stopwatch
  /// to zero — so the anchor is trustworthy only when this matches the flushing
  /// process's boot id. Null on legacy entries (and any not routed through
  /// [ClaimOutbox.add]); those fall back to the stored wall clock, never the
  /// anchor.
  final String? capturedBootId;

  /// A copy stamped with its owning account (see [uid]).
  OutboxEntry ownedBy(String? owner) => OutboxEntry(
        scanId: scanId,
        lat: lat,
        lng: lng,
        capturedWallMs: capturedWallMs,
        capturedMonotonicMs: capturedMonotonicMs,
        attemptId: attemptId,
        uid: owner,
        capturedBootId: capturedBootId,
      );

  /// A copy stamped with the capturing process's boot id (see [capturedBootId]).
  OutboxEntry withBootId(String? bootId) => OutboxEntry(
        scanId: scanId,
        lat: lat,
        lng: lng,
        capturedWallMs: capturedWallMs,
        capturedMonotonicMs: capturedMonotonicMs,
        attemptId: attemptId,
        uid: uid,
        capturedBootId: bootId,
      );

  /// The capture time to send at flush: monotonic-anchored ONLY when the
  /// flushing process is the one that took the capture ([capturedBootId] ==
  /// [flushBootId]); otherwise the stored wall clock.
  ///
  /// The boot-id match is essential. A restart resets the monotonic stopwatch
  /// to zero, so once a NEW process has been alive longer (in ms) than the old
  /// capture's stored monotonic value, a bare `flushMonotonic >=
  /// capturedMonotonic` guard becomes true again and would wrongly re-take the
  /// anchor — reporting the capture as ~now and mis-dating an offline claim to
  /// the flush day (which can silently break the very streak the offline path
  /// exists to save). Legacy entries (null [capturedBootId]) always fall back.
  int capturedAtForFlush({
    required int flushWallMs,
    required int flushMonotonicMs,
    String? flushBootId,
  }) {
    final sameProcess =
        capturedBootId != null && capturedBootId == flushBootId;
    if (sameProcess && flushMonotonicMs >= capturedMonotonicMs) {
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
        if (capturedBootId != null) 'capturedBootId': capturedBootId!,
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
    final bootId = raw['capturedBootId'];
    return OutboxEntry(
      scanId: scanId,
      lat: lat.toDouble(),
      lng: lng.toDouble(),
      capturedWallMs: wall.toInt(),
      capturedMonotonicMs: mono.toInt(),
      attemptId: attemptId,
      uid: uid is String ? uid : null,
      capturedBootId: bootId is String ? bootId : null,
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

  /// A random id minted once per OS process. Stamped onto every capture (see
  /// [add]) and passed to [OutboxEntry.capturedAtForFlush] at flush time so the
  /// monotonic anchor is only trusted within the process that took the capture
  /// — [_monotonic] resets on restart, so a stored monotonic value from a
  /// previous process is not comparable to this one's.
  static final String _bootId = newAttemptId();
  static String bootId() => _bootId;

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

  /// Bank a capture for the signed-in user. The owner AND the capturing
  /// process's boot id are stamped here rather than at the call site so no
  /// caller can forget either — both describe state only the current process
  /// knows: the signed-in user, and which process
  /// [OutboxEntry.capturedMonotonicMs] belongs to.
  Future<void> add(OutboxEntry entry) async {
    final list = await _load();
    var stamped = entry;
    if (stamped.uid == null) stamped = stamped.ownedBy(_uidProvider());
    if (stamped.capturedBootId == null) stamped = stamped.withBootId(_bootId);
    list.add(stamped);
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
