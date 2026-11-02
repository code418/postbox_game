// Workout claims (Health Connect): the orchestration layer.
//
// Reads the player's recent walking / running / hiking sessions from Health
// Connect, sends each NEW session's GPS route once to `matchActivityRoute`
// (which returns signed candidates for the postboxes it passed), keeps those
// candidates locally, and claims one via `claimActivityPostbox` after the
// cypher quiz. All the rules live in lib/activity/activity_helpers.dart; this
// class wires them to the bridge, the store and the callables.
//
// Invariants:
//  - Opt-in per game account (ActivityStore.optedIn), on top of the device's
//    Health Connect grant. Nothing is read until the player connects.
//  - The silent foreground check (autoCheck) NEVER prompts: a session whose
//    route needs a per-run OK waits for the player to tap "Check" (which is
//    the only caller of requestRouteConsent).
//  - Each version of a session is sent at most once with a final verdict.
//  - Every claim carries an attemptId; a transport failure keeps it so the
//    server replays the stored response (claimActivityPostbox is the second
//    non-idempotent write after startScoring, made safe the same way).
//  - Nothing derived from Health Connect goes to Analytics or Crashlytics.

import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:postbox_game/activity/activity_helpers.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/firebase_functions_eu.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/services/activity_store.dart';
import 'package:postbox_game/services/connectivity_service.dart';
import 'package:postbox_game/services/device_id_service.dart';
import 'package:postbox_game/services/health_connect_bridge.dart';

/// Matches [HttpsCallable.call]; injectable for tests.
typedef ActivityCallableFn = Future<HttpsCallableResult<dynamic>> Function(Map<String, dynamic>);

enum ActivityCheckTrigger { resume, manual }

/// What a check did.
@immutable
class ActivityCheckSummary {
  const ActivityCheckSummary({
    this.checked = 0,
    this.newCandidates = 0,
    this.consentNeeded = 0,
    this.error,
  });

  /// Sessions whose routes were read this time.
  final int checked;

  /// Candidates added this time (never announced before, by construction).
  final int newCandidates;

  /// Sessions that newly need a per-run route OK.
  final int consentNeeded;

  /// Why the check stopped early: offline | quota_exceeded | not_available |
  /// maintenance | app_verification | permission_denied | error.
  final String? error;
}

enum ActivityClaimKind {
  claimed,
  alreadyClaimed,
  notFound,
  expired,
  quotaExceeded,
  notAvailable,
  maintenance,
  transport,
  appVerification,
  badToken,
  error,
}

@immutable
class ActivityClaimOutcome {
  const ActivityClaimOutcome(this.kind, {this.claimed = 0, this.points = 0, this.message});
  final ActivityClaimKind kind;
  final int claimed;
  final int points;

  /// The server's own user-facing message, when it sent one.
  final String? message;
}

/// Max sessions a silent check reads; a manual refresh reads a few more.
const int _maxAutoSessions = 5;
const int _maxManualSessions = 10;

class ActivityClaimsService {
  ActivityClaimsService({
    HealthConnectBridge? bridge,
    ActivityCallableFn? matchCallable,
    ActivityCallableFn? claimCallable,
    ActivityStore? store,
    String? Function()? uidProvider,
    int Function()? clock,
    RemoteConfigService Function()? remoteConfig,
    bool Function()? isOnline,
    Future<String?> Function()? deviceIdProvider,
  })  : _bridge = bridge ?? MethodChannelHealthConnectBridge(),
        _match = matchCallable ??
            ((data) => appFunctions.httpsCallable('matchActivityRoute').call(data)),
        _claim = claimCallable ??
            ((data) => appFunctions.httpsCallable('claimActivityPostbox').call(data)),
        _store = store ?? ActivityStore(),
        _uid = uidProvider ?? (() => FirebaseAuth.instance.currentUser?.uid),
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _remoteConfig = remoteConfig ?? (() => RemoteConfigService.instance),
        _isOnline = isOnline ?? (() => ConnectivityService.instance.online.value),
        _deviceId = deviceIdProvider ?? DeviceIdService.get;

  final HealthConnectBridge _bridge;
  final ActivityCallableFn _match;
  final ActivityCallableFn _claim;
  final ActivityStore _store;
  final String? Function() _uid;
  final int Function() _clock;
  final RemoteConfigService Function() _remoteConfig;
  final bool Function() _isOnline;
  final Future<String?> Function() _deviceId;

  static ActivityClaimsService? _instance;
  static ActivityClaimsService get instance => _instance ??= ActivityClaimsService();

  @visibleForTesting
  static set instance(ActivityClaimsService value) => _instance = value;

  @visibleForTesting
  static void resetForTest() => _instance = null;

  /// Claimable candidates the banner hasn't been told "Not now" about.
  final ValueNotifier<int> bannerCount = ValueNotifier<int>(0);

  bool _checking = false;

  HealthConnectBridge get bridge => _bridge;
  RemoteConfigService get _rc => _remoteConfig();
  int get graceMs => _rc.activityClaimGraceHours * 3600 * 1000;

  /// Whether any entry point should show at all (flag + platform). Cheap.
  bool get featureVisible => _rc.activityClaimsAvailable && _bridge.isSupportedPlatform;

  Future<HcAvailability> availability() => _bridge.availability();

  Future<Set<String>> grantedPermissions() async {
    try {
      return await _bridge.grantedPermissions();
    } on HealthConnectException {
      return const {};
    }
  }

  Future<bool> optedIn() async {
    final uid = _uid();
    return uid != null && await _store.optedIn(uid);
  }

  Future<bool> autoCheckEnabled() async {
    final uid = _uid();
    return uid != null && await _store.autoCheck(uid);
  }

  Future<void> setAutoCheckEnabled(bool v) async {
    final uid = _uid();
    if (uid != null) await _store.setAutoCheck(uid, v);
  }

  /// The current player's state (pruned to the claim window).
  Future<ActivityState> loadState() async {
    final uid = _uid();
    if (uid == null) return ActivityState();
    final s = await _store.load(uid);
    s.prune(_clock(), graceMs);
    return s;
  }

  /// Ask for the Health Connect permissions and opt this account in when
  /// reading sessions is granted. Returns the granted set.
  Future<Set<String>> connect() async {
    final uid = _uid();
    if (uid == null) return const {};
    Set<String> granted;
    try {
      granted = await _bridge.requestPermissions();
    } on HealthConnectException {
      unawaited(Analytics.activityConnect(outcome: 'unavailable'));
      return const {};
    }
    final ok = granted.contains(HealthConnectPermissions.readExercise);
    if (ok) await _store.setOptedIn(uid, true);
    unawaited(Analytics.activityConnect(
        outcome: !ok
            ? 'denied'
            : granted.contains(HealthConnectPermissions.readExerciseRoutes)
                ? 'granted'
                : 'partial'));
    return granted;
  }

  /// Revoke Health Connect access and forget this account's workout state.
  Future<void> disconnect() async {
    final uid = _uid();
    await _bridge.revokeAll();
    await _store.clear(forUid: uid);
    bannerCount.value = 0;
  }

  /// Sign-out: drop the previous player's candidates (tokens are uid-bound).
  Future<void> onSignedOut() async {
    bannerCount.value = 0;
    await _store.clear();
  }

  /// The silent foreground check. Returns null when skipped (feature off,
  /// not opted in, offline, maintenance, debounced, or already running).
  Future<ActivityCheckSummary?> autoCheck() async {
    if (!featureVisible || _checking) return null;
    final uid = _uid();
    if (uid == null || _rc.maintenanceMode || !_isOnline()) return null;
    if (!await _store.optedIn(uid) || !await _store.autoCheck(uid)) return null;
    final now = _clock();
    if (!autoCheckDue(await _store.lastAutoCheckMs(uid), now)) return null;
    if (await _bridge.availability() != HcAvailability.available) return null;
    if (!(await grantedPermissions()).contains(HealthConnectPermissions.readExercise)) return null;
    await _store.setLastAutoCheckMs(uid, now);
    return _check(uid, ActivityCheckTrigger.resume, _maxAutoSessions);
  }

  /// A check the player asked for (pull to refresh). Still never prompts for
  /// route access — that is [checkWithConsent].
  Future<ActivityCheckSummary> refresh() async {
    final uid = _uid();
    if (uid == null || !featureVisible) return const ActivityCheckSummary(error: 'not_available');
    if (_checking) return const ActivityCheckSummary();
    if (_rc.maintenanceMode) return const ActivityCheckSummary(error: 'maintenance');
    return _check(uid, ActivityCheckTrigger.manual, _maxManualSessions);
  }

  /// The player tapped "Check" on a session whose route needs a per-run OK:
  /// show Health Connect's prompt, then match the route if they allow it.
  Future<ActivityCheckSummary> checkWithConsent(HcSession session) async {
    final uid = _uid();
    if (uid == null || !featureVisible) return const ActivityCheckSummary(error: 'not_available');
    if (_checking) return const ActivityCheckSummary();
    _checking = true;
    try {
      final state = await _store.load(uid);
      HcRouteResult route;
      try {
        route = await _bridge.requestRouteConsent(session.id);
      } on HealthConnectException catch (e) {
        return ActivityCheckSummary(error: e.code);
      }
      final r = await _processRoute(state, session, route);
      await _store.save(uid, state);
      _updateBanner(state);
      return ActivityCheckSummary(checked: 1, newCandidates: r.added, error: r.stop);
    } finally {
      _checking = false;
    }
  }

  Future<ActivityCheckSummary> _check(String uid, ActivityCheckTrigger trigger, int maxSessions) async {
    _checking = true;
    final triggerName = trigger == ActivityCheckTrigger.resume ? 'resume' : 'manual';
    try {
      final now = _clock();
      final state = await _store.load(uid);
      state.prune(now, graceMs);
      List<HcSession> sessions;
      try {
        sessions = await _bridge.readSessions(
          // A session that ENDED inside the window may have started up to
          // 12 h earlier.
          sinceMs: now - graceMs - maxSessionDuration.inMilliseconds,
          untilMs: now + const Duration(minutes: 5).inMilliseconds,
        );
      } on HealthConnectException catch (e) {
        unawaited(Analytics.activityCheck(trigger: triggerName, outcome: 'error'));
        return ActivityCheckSummary(error: e.code);
      }
      final todo = eligibleSessions(sessions,
          nowMs: now,
          graceMs: graceMs,
          originAllowlist: _rc.activityOriginAllowlist,
          processedKeys: state.processedKeys);
      var checked = 0;
      var added = 0;
      var consent = 0;
      String? stop;
      for (final s in todo.take(maxSessions)) {
        final wasConsent = state.sessions[s.versionKey]?.verdict == 'consent_required';
        HcRouteResult route;
        try {
          route = await _bridge.readRoute(s.id);
        } on HealthConnectException catch (e) {
          stop = e.code == 'permission_denied' ? 'permission_denied' : 'error';
          break;
        }
        checked++;
        final r = await _processRoute(state, s, route);
        added += r.added;
        if (r.consent && !wasConsent) consent++;
        if (r.stop != null) {
          stop = r.stop;
          break;
        }
      }
      await _store.save(uid, state);
      _updateBanner(state);
      unawaited(Analytics.activityCheck(
          trigger: triggerName,
          outcome: stop != null
              ? 'error'
              : added > 0
                  ? 'candidates'
                  : consent > 0
                      ? 'consent_needed'
                      : 'none'));
      return ActivityCheckSummary(checked: checked, newCandidates: added, consentNeeded: consent, error: stop);
    } finally {
      _checking = false;
    }
  }

  /// Record a session's route outcome; match it when there is a route.
  Future<({int added, bool consent, String? stop})> _processRoute(
      ActivityState state, HcSession s, HcRouteResult route) async {
    final now = _clock();
    void record(String verdict, {int passed = 0, int alreadyClaimed = 0}) {
      state.sessions[s.versionKey] = SessionRecord(
          session: s, verdict: verdict, checkedAtMs: now, passed: passed, alreadyClaimed: alreadyClaimed);
    }

    switch (route) {
      case HcRouteConsentRequired():
      case HcRouteUnsupported():
        record('consent_required');
        return (added: 0, consent: true, stop: null);
      case HcRouteDenied():
        record('denied');
        return (added: 0, consent: false, stop: null);
      case HcRouteNoData():
        record('no_route');
        return (added: 0, consent: false, stop: null);
      case HcRouteData(:final points):
        final simplified = simplifyRoute(points);
        if (simplified.length < 2) {
          record('no_route');
          return (added: 0, consent: false, stop: null);
        }
        try {
          // Safe to retry: matching is read-only server-side (an unchanged
          // route re-matches free of quota).
          final res = await retryOnUnavailable(() => _match(encodeRoutePayload(s, simplified)));
          final data = Map<String, dynamic>.from(res.data as Map);
          if (data['ok'] != true) {
            final reason = data['reason'];
            record(reason is String && reason.isNotEmpty ? reason : 'error');
            return (added: 0, consent: false, stop: null);
          }
          final raw = data['candidates'];
          final candidates = raw is List
              ? raw.map((c) => ActivityCandidate.tryParse(c, session: s)).whereType<ActivityCandidate>().toList()
              : <ActivityCandidate>[];
          final already = data['alreadyClaimed'];
          record('ok',
              passed: candidates.fold(0, (n, c) => n + c.boxes.length),
              alreadyClaimed: already is num ? already.toInt() : 0);
          return (added: state.addCandidates(candidates), consent: false, stop: null);
        } on FirebaseFunctionsException catch (e) {
          final reason = _reason(e);
          if (retryableCallableCodes.contains(e.code)) {
            return (added: 0, consent: false, stop: reason == 'maintenance' ? 'maintenance' : 'offline');
          }
          switch (e.code) {
            case 'resource-exhausted':
              return (added: 0, consent: false, stop: 'quota_exceeded');
            case 'permission-denied':
            case 'failed-precondition':
              return (added: 0, consent: false, stop: 'not_available');
            case appVerificationFailedCode:
              return (added: 0, consent: false, stop: 'app_verification');
            case 'invalid-argument':
              // A payload the server can't read won't improve on resubmission.
              record('error');
              return (added: 0, consent: false, stop: null);
            default:
              return (added: 0, consent: false, stop: 'error');
          }
        }
    }
  }

  static String? _reason(FirebaseFunctionsException e) {
    final d = e.details;
    if (d is Map && d['reason'] is String) return d['reason'] as String;
    return null;
  }

  /// Claim a candidate (after the quiz). [attemptId] must be kept across
  /// transport retries of the same claim and discarded after any definitive
  /// answer — the caller owns it (see ActivityClaimSheet).
  Future<ActivityClaimOutcome> claim(ActivityCandidate c, {required String attemptId}) async {
    final uid = _uid();
    if (uid == null) return const ActivityClaimOutcome(ActivityClaimKind.error);
    ActivityClaimOutcome outcome;
    try {
      final deviceIdHash = await _deviceId();
      // Safe to auto-retry ONLY because attemptId makes the call idempotent
      // server-side (functions/src/_attempts.ts).
      final res = await retryOnUnavailable(() => _claim(<String, dynamic>{
            'token': c.token,
            'attemptId': attemptId,
            'clientTsMs': _clock(),
            if (deviceIdHash != null) 'deviceIdHash': deviceIdHash,
          }));
      final data = Map<String, dynamic>.from(res.data as Map);
      final claimedRaw = data['claimed'];
      final pointsRaw = data['points'];
      final claimed = claimedRaw is num ? claimedRaw.toInt() : 0;
      final points = pointsRaw is num ? pointsRaw.toInt() : 0;
      if (data['found'] != true) {
        outcome = const ActivityClaimOutcome(ActivityClaimKind.notFound);
      } else if (data['allClaimedToday'] == true || claimed == 0) {
        outcome = const ActivityClaimOutcome(ActivityClaimKind.alreadyClaimed);
      } else {
        outcome = ActivityClaimOutcome(ActivityClaimKind.claimed, claimed: claimed, points: points);
      }
    } on FirebaseFunctionsException catch (e) {
      final reason = _reason(e);
      if (retryableCallableCodes.contains(e.code)) {
        outcome = ActivityClaimOutcome(
            reason == 'maintenance' ? ActivityClaimKind.maintenance : ActivityClaimKind.transport);
      } else if (e.code == 'resource-exhausted') {
        outcome = const ActivityClaimOutcome(ActivityClaimKind.quotaExceeded);
      } else if (reason == 'expired') {
        outcome = const ActivityClaimOutcome(ActivityClaimKind.expired);
      } else if (reason == 'bad_token' || reason == 'stale_token') {
        outcome = const ActivityClaimOutcome(ActivityClaimKind.badToken);
      } else if (reason == 'not_available' || e.code == 'permission-denied') {
        outcome = const ActivityClaimOutcome(ActivityClaimKind.notAvailable);
      } else if (e.code == appVerificationFailedCode) {
        outcome = const ActivityClaimOutcome(ActivityClaimKind.appVerification);
      } else {
        outcome = ActivityClaimOutcome(ActivityClaimKind.error, message: e.message);
      }
    } catch (_) {
      outcome = const ActivityClaimOutcome(ActivityClaimKind.error);
    }

    // Settle the candidate locally for every definitive answer.
    final state = await _store.load(uid);
    final now = _clock();
    switch (outcome.kind) {
      case ActivityClaimKind.claimed:
      case ActivityClaimKind.alreadyClaimed:
        state.claimed[c.key] = now;
      case ActivityClaimKind.notFound:
      case ActivityClaimKind.expired:
      case ActivityClaimKind.badToken:
        state.dismissed[c.key] = now;
      default:
        break;
    }
    await _store.save(uid, state);
    _updateBanner(state);
    unawaited(Analytics.activityClaim(
        outcome: switch (outcome.kind) {
          ActivityClaimKind.claimed => 'success',
          ActivityClaimKind.alreadyClaimed => 'already_claimed',
          ActivityClaimKind.notFound => 'not_found',
          ActivityClaimKind.expired => 'expired',
          _ => 'error',
        }));
    return outcome;
  }

  /// The player skipped a candidate ("I didn't spot it").
  Future<void> dismiss(ActivityCandidate c) async {
    final uid = _uid();
    if (uid == null) return;
    final state = await _store.load(uid);
    state.dismissed[c.key] = _clock();
    await _store.save(uid, state);
    _updateBanner(state);
    unawaited(Analytics.activityClaim(outcome: 'dismissed'));
  }

  /// Banner "Not now": hide the current claimables from the banner (the
  /// screen still lists them).
  Future<void> snoozeBanner() async {
    final uid = _uid();
    if (uid == null) return;
    final state = await _store.load(uid);
    final now = _clock();
    for (final c in state.claimable(now, graceMs)) {
      state.snoozed[c.key] = now;
    }
    await _store.save(uid, state);
    _updateBanner(state);
  }

  /// Recompute [bannerCount] from the stored state (e.g. on screen open).
  Future<void> refreshBanner() async {
    // Flag first: with the feature off this touches neither Auth nor storage.
    if (!featureVisible) {
      bannerCount.value = 0;
      return;
    }
    final uid = _uid();
    if (uid == null) {
      bannerCount.value = 0;
      return;
    }
    _updateBanner(await _store.load(uid));
  }

  void _updateBanner(ActivityState state) {
    final now = _clock();
    bannerCount.value = featureVisible
        ? state.claimable(now, graceMs).where((c) => !state.snoozed.containsKey(c.key)).length
        : 0;
  }
}
