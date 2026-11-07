// Local state for workout claims (SharedPreferences, JSON).
//
// UID-STAMPED, for the same reason as ClaimOutbox: candidate tokens are bound
// to the account that matched them, and Health Connect permissions are per
// DEVICE, not per game account. A different account signing in on the same
// phone must neither see nor claim the previous player's workouts — so the
// state document carries its owner's uid and reads as empty for anyone else,
// and the opt-in is stored per uid (a grant made by account A doesn't opt
// account B in).

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:postbox_game/activity/activity_helpers.dart';
import 'package:postbox_game/services/health_connect_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What happened when a session was checked.
class SessionRecord {
  const SessionRecord({
    required this.session,
    required this.verdict,
    required this.checkedAtMs,
    this.passed = 0,
    this.alreadyClaimed = 0,
  });

  final HcSession session;

  /// "ok", "consent_required", "no_route", "denied", or a server reason.
  final String verdict;
  final int checkedAtMs;
  final int passed;
  final int alreadyClaimed;

  /// Verdicts that won't change for this version of the session: never
  /// re-read or re-sent. consent_required / denied are retried on request.
  bool get isFinal => verdict != 'consent_required' && verdict != 'denied';

  Map<String, Object> toJson() => {
        'session': session.toJson(),
        'verdict': verdict,
        'checkedAtMs': checkedAtMs,
        'passed': passed,
        'alreadyClaimed': alreadyClaimed,
      };

  static SessionRecord? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final s = HcSession.tryParse(raw['session']);
    final v = raw['verdict'];
    final at = raw['checkedAtMs'];
    if (s == null || v is! String || at is! num) return null;
    final passed = raw['passed'];
    final already = raw['alreadyClaimed'];
    return SessionRecord(
      session: s,
      verdict: v,
      checkedAtMs: at.toInt(),
      passed: passed is num ? passed.toInt() : 0,
      alreadyClaimed: already is num ? already.toInt() : 0,
    );
  }
}

/// The whole per-user state document.
class ActivityState {
  ActivityState({
    Map<String, SessionRecord>? sessions,
    List<ActivityCandidate>? candidates,
    Map<String, int>? claimed,
    Map<String, int>? dismissed,
    Map<String, int>? announced,
    Map<String, int>? snoozed,
  })  : sessions = sessions ?? {},
        candidates = candidates ?? [],
        claimed = claimed ?? {},
        dismissed = dismissed ?? {},
        announced = announced ?? {},
        snoozed = snoozed ?? {};

  /// Keyed by HcSession.versionKey.
  final Map<String, SessionRecord> sessions;
  final List<ActivityCandidate> candidates;

  /// Candidate key → when it happened.
  final Map<String, int> claimed;
  final Map<String, int> dismissed;

  /// James has mentioned these (announce each candidate once).
  final Map<String, int> announced;

  /// The banner's "Not now" hid these.
  final Map<String, int> snoozed;

  Set<String> get processedKeys =>
      {for (final e in sessions.entries) if (e.value.isFinal) e.key};

  List<ActivityCandidate> claimable(int nowMs, int graceMs) => candidates
      .where((c) =>
          candidateStatus(c,
              nowMs: nowMs,
              graceMs: graceMs,
              claimedKeys: claimed.keys.toSet(),
              dismissedKeys: dismissed.keys.toSet()) ==
          CandidateStatus.claimable)
      .toList()
    ..sort((a, b) => a.passedAtMs.compareTo(b.passedAtMs));

  /// Add server candidates, keeping the first copy of each key (two sessions
  /// over the same boxes on the same day collapse to one).
  int addCandidates(Iterable<ActivityCandidate> incoming) {
    final known = candidates.map((c) => c.key).toSet();
    var added = 0;
    for (final c in incoming) {
      if (known.add(c.key)) {
        candidates.add(c);
        added++;
      }
    }
    return added;
  }

  /// Drop everything older than the claim window (plus a day of slack so a
  /// just-expired card can still read "too long ago" for a while).
  void prune(int nowMs, int graceMs) {
    final cutoff = nowMs - graceMs - const Duration(days: 1).inMilliseconds;
    sessions.removeWhere((_, r) => r.session.endMs < cutoff);
    candidates.removeWhere((c) => c.passedAtMs < cutoff);
    final live = candidates.map((c) => c.key).toSet();
    for (final m in [claimed, dismissed, announced, snoozed]) {
      m.removeWhere((k, at) => !live.contains(k) && at < cutoff);
    }
  }

  Map<String, Object> toJson() => {
        'sessions': {for (final e in sessions.entries) e.key: e.value.toJson()},
        'candidates': [for (final c in candidates) c.toJson()],
        'claimed': claimed,
        'dismissed': dismissed,
        'announced': announced,
        'snoozed': snoozed,
      };

  static Map<String, int> _intMap(Object? raw) => raw is Map
      ? {
          for (final e in raw.entries)
            if (e.key is String && e.value is num) e.key as String: (e.value as num).toInt()
        }
      : {};

  static ActivityState fromJson(Object? raw) {
    if (raw is! Map) return ActivityState();
    final sessions = <String, SessionRecord>{};
    final rawSessions = raw['sessions'];
    if (rawSessions is Map) {
      for (final e in rawSessions.entries) {
        final r = SessionRecord.tryParse(e.value);
        if (e.key is String && r != null) sessions[e.key as String] = r;
      }
    }
    final rawCandidates = raw['candidates'];
    return ActivityState(
      sessions: sessions,
      candidates: rawCandidates is List
          ? rawCandidates.map((c) => ActivityCandidate.tryParse(c)).whereType<ActivityCandidate>().toList()
          : [],
      claimed: _intMap(raw['claimed']),
      dismissed: _intMap(raw['dismissed']),
      announced: _intMap(raw['announced']),
      snoozed: _intMap(raw['snoozed']),
    );
  }
}

class ActivityStore {
  ActivityStore({Future<SharedPreferences> Function()? prefsProvider})
      : _prefs = prefsProvider ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _prefs;

  @visibleForTesting
  static const String stateKey = 'activity_claims_v1';
  static String _optInKey(String uid) => 'activity_opt_in_$uid';
  static String _autoKey(String uid) => 'activity_auto_check_$uid';
  static String _lastKey(String uid) => 'activity_last_auto_check_$uid';

  /// The state for [uid]; empty when the stored document belongs to anyone
  /// else (or is missing / corrupt).
  Future<ActivityState> load(String uid) async {
    try {
      final raw = (await _prefs()).getString(stateKey);
      if (raw == null) return ActivityState();
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['uid'] != uid) return ActivityState();
      return ActivityState.fromJson(decoded['state']);
    } catch (_) {
      return ActivityState();
    }
  }

  Future<void> save(String uid, ActivityState state) async {
    try {
      await (await _prefs()).setString(stateKey, jsonEncode({'uid': uid, 'state': state.toJson()}));
    } catch (e) {
      debugPrint('ActivityStore.save failed: $e');
    }
  }

  /// Forget the candidate/session state (sign-out, disconnect). The per-uid
  /// opt-in and auto-check choices are kept unless [forUid] asks otherwise.
  Future<void> clear({String? forUid}) async {
    try {
      final p = await _prefs();
      await p.remove(stateKey);
      if (forUid != null) {
        await p.remove(_optInKey(forUid));
        await p.remove(_lastKey(forUid));
      }
    } catch (_) {}
  }

  Future<bool> optedIn(String uid) async {
    try {
      return (await _prefs()).getBool(_optInKey(uid)) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> setOptedIn(String uid, bool v) async {
    try {
      await (await _prefs()).setBool(_optInKey(uid), v);
    } catch (_) {}
  }

  /// Defaults to on once connected (the user connected to get this).
  Future<bool> autoCheck(String uid) async {
    try {
      return (await _prefs()).getBool(_autoKey(uid)) ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> setAutoCheck(String uid, bool v) async {
    try {
      await (await _prefs()).setBool(_autoKey(uid), v);
    } catch (_) {}
  }

  Future<int?> lastAutoCheckMs(String uid) async {
    try {
      return (await _prefs()).getInt(_lastKey(uid));
    } catch (_) {
      return null;
    }
  }

  Future<void> setLastAutoCheckMs(String uid, int ms) async {
    try {
      await (await _prefs()).setInt(_lastKey(uid), ms);
    } catch (_) {}
  }
}
