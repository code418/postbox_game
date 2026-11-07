// Pure helpers for workout claims (Health Connect). No Flutter widgets, no
// platform calls — every rule that decides what is read, what is sent and
// what is offered lives here so it can be unit-tested directly.

import 'dart:math' as math;

import 'package:postbox_game/services/health_connect_bridge.dart';

/// Exercise types that may claim. Mirrored in the Kotlin bridge
/// (HealthConnectMapping.ELIGIBLE_EXERCISE_TYPES) and the server
/// (functions/src/_activityConfig.ts ELIGIBLE_EXERCISE_TYPES); pinned by
/// test/cross_language_sync_test.dart.
const List<String> eligibleExerciseTypes = ['walking', 'running', 'hiking'];

/// Sessions shorter than this are almost always accidental starts.
const Duration minSessionDuration = Duration(minutes: 2);

/// Matches the server's MAX_SESSION_MS.
const Duration maxSessionDuration = Duration(hours: 12);

/// Health Connect may report a session ending a moment in the future (clock
/// skew between the watch and the phone).
const Duration _futureSlack = Duration(minutes: 5);

/// Eligible sessions to check, newest first: an on-foot type, not typed in by
/// hand, ended within the claim window, a plausible length, recorded by an
/// allow-listed fitness app, and not already processed in this version.
List<HcSession> eligibleSessions(
  List<HcSession> all, {
  required int nowMs,
  required int graceMs,
  required List<String> originAllowlist,
  Set<String> processedKeys = const {},
}) {
  final out = all.where((s) {
    if (!eligibleExerciseTypes.contains(s.type)) return false;
    if (s.recordingMethod == 'manual') return false;
    if (processedKeys.contains(s.versionKey)) return false;
    if (s.endMs > nowMs + _futureSlack.inMilliseconds) return false;
    if (nowMs - s.endMs > graceMs) return false;
    final d = s.endMs - s.startMs;
    if (d < minSessionDuration.inMilliseconds || d > maxSessionDuration.inMilliseconds) {
      return false;
    }
    return originAllowlist.contains(s.originPackage);
  }).toList()
    ..sort((a, b) => b.endMs.compareTo(a.endMs));
  return out;
}

const double _mPerDegLat = 111319.5;

double _mPerDegLng(double lat) => _mPerDegLat * math.cos(lat * math.pi / 180);

/// Perpendicular distance (metres, local tangent plane) from [p] to [a]→[b].
double _perpDistanceM(HcRoutePoint p, HcRoutePoint a, HcRoutePoint b) {
  final mLng = _mPerDegLng((a.lat + b.lat) / 2);
  final bx = (b.lng - a.lng) * mLng;
  final by = (b.lat - a.lat) * _mPerDegLat;
  final px = (p.lng - a.lng) * mLng;
  final py = (p.lat - a.lat) * _mPerDegLat;
  final len2 = bx * bx + by * by;
  final t = len2 > 0 ? ((px * bx + py * by) / len2).clamp(0.0, 1.0) : 0.0;
  final dx = px - t * bx;
  final dy = py - t * by;
  return math.sqrt(dx * dx + dy * dy);
}

/// Simplify a recorded route before it is sent (smaller payload, fewer
/// points to validate) without changing which postboxes it passed:
///
///  - drops non-finite fixes and fixes worse than [maxAccuracyM];
///  - Douglas–Peucker at [toleranceM] (every dropped fix lies within the
///    tolerance of the kept polyline, far inside the 30 m claim radius);
///  - always keeps a fix at least every [maxGapMs], so the server's pass-time
///    interpolation never spans a long stretch and a genuine GPS dropout
///    still reads as a dropout;
///  - if the result exceeds [maxPoints], retries with a 1.5× tolerance.
List<HcRoutePoint> simplifyRoute(
  List<HcRoutePoint> input, {
  double toleranceM = 5,
  int maxPoints = 4000,
  double maxAccuracyM = 50,
  int maxGapMs = 60000,
}) {
  final pts = input
      .where((p) =>
          p.lat.isFinite && p.lng.isFinite &&
          p.lat >= -90 && p.lat <= 90 && p.lng >= -180 && p.lng <= 180 &&
          (p.accuracyM == null || p.accuracyM! <= maxAccuracyM))
      .toList()
    ..sort((a, b) => a.tMs.compareTo(b.tMs));
  if (pts.length <= 2) return pts;

  // Forced keeps: endpoints plus whatever the max-gap rule demands.
  final forced = <int>{0, pts.length - 1};
  var lastKept = 0;
  for (var i = 1; i < pts.length; i++) {
    if (pts[i].tMs - pts[lastKept].tMs > maxGapMs) {
      final k = i - 1 > lastKept ? i - 1 : i;
      forced.add(k);
      lastKept = k;
    }
  }
  final anchors = forced.toList()..sort();

  var tol = toleranceM;
  while (true) {
    final keep = List<bool>.filled(pts.length, false);
    for (final a in anchors) {
      keep[a] = true;
    }
    for (var s = 0; s < anchors.length - 1; s++) {
      final stack = <List<int>>[[anchors[s], anchors[s + 1]]];
      while (stack.isNotEmpty) {
        final seg = stack.removeLast();
        final lo = seg[0];
        final hi = seg[1];
        if (hi - lo < 2) continue;
        var maxD = -1.0;
        var idx = -1;
        for (var i = lo + 1; i < hi; i++) {
          final d = _perpDistanceM(pts[i], pts[lo], pts[hi]);
          if (d > maxD) {
            maxD = d;
            idx = i;
          }
        }
        if (maxD > tol) {
          keep[idx] = true;
          stack
            ..add([lo, idx])
            ..add([idx, hi]);
        }
      }
    }
    final out = [
      for (var i = 0; i < pts.length; i++)
        if (keep[i]) pts[i],
    ];
    if (out.length <= maxPoints || tol > 200) return out;
    tol *= 1.5;
  }
}

/// The matchActivityRoute payload for one session (compact parallel arrays,
/// times relative to the session start, coordinates at 6 dp ≈ 0.1 m).
Map<String, Object> encodeRoutePayload(HcSession s, List<HcRoutePoint> route) {
  double r6(double v) => (v * 1e6).roundToDouble() / 1e6;
  return {
    'source': 'health_connect',
    'session': {
      'id': s.id,
      'lastModifiedMs': s.lastModifiedMs,
      'exerciseType': s.type,
      'originPackage': s.originPackage,
      'recordingMethod': s.recordingMethod,
      'startMs': s.startMs,
      'endMs': s.endMs,
    },
    'route': {
      'dtMs': [for (final p in route) p.tMs - s.startMs],
      'lat': [for (final p in route) r6(p.lat)],
      'lng': [for (final p in route) r6(p.lng)],
    },
  };
}

/// One box in a candidate (monarch drives the quiz; points are display-only).
class CandidateBox {
  const CandidateBox({this.monarch, required this.points});
  final String? monarch;
  final int points;

  Map<String, Object> toJson() => {if (monarch != null) 'monarch': monarch!, 'points': points};

  static CandidateBox? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final m = raw['monarch'];
    final p = raw['points'];
    if (p is! num) return null;
    return CandidateBox(monarch: m is String && m.isNotEmpty ? m : null, points: p.toInt());
  }
}

/// A group of postboxes a workout passed together: one quiz, one claim.
class ActivityCandidate {
  const ActivityCandidate({
    required this.token,
    required this.key,
    required this.passedAtMs,
    required this.claimDate,
    required this.boxes,
    required this.sessionId,
    required this.exerciseType,
    required this.originPackage,
  });

  /// Server-signed claim token (opaque to the app).
  final String token;

  /// Opaque per-user key for (boxes, day): de-duplicates across sessions.
  final String key;
  final int passedAtMs;

  /// London day the claim will count for (YYYY-MM-DD).
  final String claimDate;
  final List<CandidateBox> boxes;
  final String sessionId;
  final String exerciseType;
  final String originPackage;

  int get totalPoints => boxes.fold(0, (s, b) => s + b.points);

  Map<String, Object> toJson() => {
        'token': token,
        'key': key,
        'passedAtMs': passedAtMs,
        'claimDate': claimDate,
        'boxes': [for (final b in boxes) b.toJson()],
        'sessionId': sessionId,
        'exerciseType': exerciseType,
        'originPackage': originPackage,
      };

  static ActivityCandidate? tryParse(Object? raw, {HcSession? session}) {
    if (raw is! Map) return null;
    final token = raw['token'];
    final key = raw['key'];
    final passed = raw['passedAtMs'];
    final day = raw['claimDate'];
    final boxes = raw['boxes'];
    if (token is! String || key is! String || passed is! num || day is! String || boxes is! List) {
      return null;
    }
    final parsedBoxes = boxes.map(CandidateBox.tryParse).whereType<CandidateBox>().toList();
    if (parsedBoxes.isEmpty) return null;
    final sessionId = session?.id ?? raw['sessionId'];
    final type = session?.type ?? raw['exerciseType'];
    final origin = session?.originPackage ?? raw['originPackage'];
    if (sessionId is! String || type is! String || origin is! String) return null;
    return ActivityCandidate(
      token: token,
      key: key,
      passedAtMs: passed.toInt(),
      claimDate: day,
      boxes: parsedBoxes,
      sessionId: sessionId,
      exerciseType: type,
      originPackage: origin,
    );
  }
}

enum CandidateStatus { claimable, claimed, dismissed, expired }

CandidateStatus candidateStatus(
  ActivityCandidate c, {
  required int nowMs,
  required int graceMs,
  Set<String> claimedKeys = const {},
  Set<String> dismissedKeys = const {},
}) {
  if (claimedKeys.contains(c.key)) return CandidateStatus.claimed;
  if (dismissedKeys.contains(c.key)) return CandidateStatus.dismissed;
  if (nowMs - c.passedAtMs > graceMs) return CandidateStatus.expired;
  return CandidateStatus.claimable;
}

/// Whether a silent foreground check is due (debounces resume storms, e.g.
/// returning from Health Connect's own permission screen).
bool autoCheckDue(int? lastCheckMs, int nowMs,
    {Duration minInterval = const Duration(minutes: 20)}) =>
    lastCheckMs == null || nowMs - lastCheckMs >= minInterval.inMilliseconds || nowMs < lastCheckMs;

/// What the Settings "Workouts" row should offer.
enum HealthConnectSettingsAction { none, install, update, connect, grantRoutes, manage }

HealthConnectSettingsAction healthConnectSettingsAction({
  required HcAvailability availability,
  required Set<String> granted,
  required bool optedIn,
}) {
  switch (availability) {
    case HcAvailability.unsupported:
      return HealthConnectSettingsAction.none;
    case HcAvailability.notInstalled:
      return HealthConnectSettingsAction.install;
    case HcAvailability.updateRequired:
      return HealthConnectSettingsAction.update;
    case HcAvailability.available:
      if (!optedIn || !granted.contains(HealthConnectPermissions.readExercise)) {
        return HealthConnectSettingsAction.connect;
      }
      if (!granted.contains(HealthConnectPermissions.readExerciseRoutes)) {
        return HealthConnectSettingsAction.grantRoutes;
      }
      return HealthConnectSettingsAction.manage;
  }
}

/// Friendly name for the app that recorded a workout.
String originLabel(String pkg) => switch (pkg) {
      'com.fitbit.FitbitMobile' => 'Fitbit',
      'com.google.android.apps.fitness' => 'Google Fit',
      'com.sec.android.app.shealth' => 'Samsung Health',
      'com.garmin.android.apps.connectmobile' => 'Garmin Connect',
      'com.strava' => 'Strava',
      _ => 'a fitness app',
    };

/// "run" / "walk" / "hike".
String sessionNoun(String type) => switch (type) { 'running' => 'run', 'hiking' => 'hike', _ => 'walk' };

/// "Morning run", "Evening walk"… from the session's local start time.
String sessionTitle(HcSession s) {
  final hour = DateTime.fromMillisecondsSinceEpoch(s.startMs).hour;
  final part = hour < 12 ? 'Morning' : (hour < 17 ? 'Afternoon' : 'Evening');
  return '$part ${sessionNoun(s.type)}';
}

/// "07:42" in local time.
String clockTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

/// Copy for a per-session verdict from the server (or the client).
String verdictLabel(String verdict) => switch (verdict) {
      'manual_entry' => 'Typed-in workout, no GPS route',
      'origin_not_supported' => "Recorded by an app we can't use yet",
      'exercise_type_not_supported' => 'Not a walk, run or hike',
      'expired' => 'Too long ago to claim',
      'implausible_speed' => 'Too fast to be on foot',
      'outside_region' => 'Outside the UK',
      'route_too_large' || 'route_too_long' || 'too_many_points' || 'too_long_duration' =>
        'Too long a workout to check',
      'no_route' => 'No GPS route recorded',
      'consent_required' => 'Needs route access',
      'denied' => 'Route access declined',
      _ => "Couldn't check this one",
    };
