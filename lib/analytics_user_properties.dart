import 'package:postbox_game/london_date.dart';
import 'package:postbox_game/streak_service.dart' show freshStreak;

/// Property-name constants for the eight Firebase Analytics user properties
/// the app reports. Mirror these in the Firebase Console (Analytics →
/// Configure → Custom definitions) so they appear in Remote Config audience
/// targeting and Analytics filters. Values are always strings — Firebase
/// stores user properties as strings and continuous numbers don't audience
/// well anyway, so bucket up-front via the helpers in this file.
class AnalyticsUserProps {
  AnalyticsUserProps._();

  static const String kIsAdmin = 'is_admin';
  static const String kHasSeenIntro = 'has_seen_intro';
  static const String kClaimStreakBucket = 'claim_streak_bucket';
  static const String kLifetimePointsBucket = 'lifetime_points_bucket';
  static const String kUniquePostboxesBucket = 'unique_postboxes_bucket';
  static const String kFriendCountBucket = 'friend_count_bucket';
  static const String kClaimedToday = 'claimed_today';
  static const String kMapColor = 'map_color';

  /// Stable ordered list of every property key — drives the admin debug card
  /// and prevents silent drift between the constants and the snapshot.
  static const List<String> all = <String>[
    kIsAdmin,
    kHasSeenIntro,
    kClaimStreakBucket,
    kLifetimePointsBucket,
    kUniquePostboxesBucket,
    kFriendCountBucket,
    kClaimedToday,
    kMapColor,
  ];
}

String boolProp(bool v) => v ? 'true' : 'false';

String streakBucket(int n) {
  if (n <= 0) return '0';
  if (n <= 3) return '1-3';
  if (n <= 7) return '4-7';
  if (n <= 30) return '8-30';
  return '30+';
}

String lifetimePointsBucket(int n) {
  if (n <= 0) return '0';
  if (n <= 100) return '1-100';
  if (n <= 1000) return '101-1000';
  if (n <= 10000) return '1001-10000';
  return '10000+';
}

String uniquePostboxesBucket(int n) {
  if (n <= 0) return '0';
  if (n <= 10) return '1-10';
  if (n <= 50) return '11-50';
  if (n <= 200) return '51-200';
  return '200+';
}

String friendCountBucket(int n) {
  if (n <= 0) return '0';
  if (n <= 3) return '1-3';
  if (n <= 10) return '4-10';
  return '11+';
}

/// String value of `users/{uid}.mapColor`. Empty / missing maps to
/// `"default"` so Remote Config audiences can target users on the
/// auto-palette without enumerating every concrete colour key.
String mapColorProp(Object? raw) {
  if (raw is String && raw.trim().isNotEmpty) return raw;
  return 'default';
}

/// Immutable bag of the eight user-property values. Use [toMap] to get a
/// {key: value} map keyed by [AnalyticsUserProps.all].
class UserPropertiesSnapshot {
  const UserPropertiesSnapshot({
    required this.isAdmin,
    required this.hasSeenIntro,
    required this.claimStreakBucket,
    required this.lifetimePointsBucket,
    required this.uniquePostboxesBucket,
    required this.friendCountBucket,
    required this.claimedToday,
    required this.mapColor,
  });

  final String isAdmin;
  final String hasSeenIntro;
  final String claimStreakBucket;
  final String lifetimePointsBucket;
  final String uniquePostboxesBucket;
  final String friendCountBucket;
  final String claimedToday;
  final String mapColor;

  Map<String, String> toMap() => <String, String>{
        AnalyticsUserProps.kIsAdmin: isAdmin,
        AnalyticsUserProps.kHasSeenIntro: hasSeenIntro,
        AnalyticsUserProps.kClaimStreakBucket: claimStreakBucket,
        AnalyticsUserProps.kLifetimePointsBucket: lifetimePointsBucket,
        AnalyticsUserProps.kUniquePostboxesBucket: uniquePostboxesBucket,
        AnalyticsUserProps.kFriendCountBucket: friendCountBucket,
        AnalyticsUserProps.kClaimedToday: claimedToday,
        AnalyticsUserProps.kMapColor: mapColor,
      };
}

/// Builds a [UserPropertiesSnapshot] from a raw `users/{uid}` Firestore doc
/// plus the two non-Firestore signals ([isAdmin] from the auth custom claim,
/// [hasSeenIntro] from SharedPreferences). [todayLondonIso] is injected so
/// tests can pin "today" deterministically; production callers should pass
/// `todayLondon()` from `lib/london_date.dart`.
///
/// Missing fields default to the "0" / "false" bucket — the same shape
/// `onUserCreated` writes for a brand-new account.
UserPropertiesSnapshot snapshotFromUserDoc(
  Map<String, dynamic> data, {
  required bool isAdmin,
  required bool hasSeenIntro,
  String? todayLondonIso,
}) {
  final today = todayLondonIso ?? todayLondon();
  final yesterday = yesterdayFor(today);
  final lastClaim = data['lastClaimDate'];
  final lastClaimStr = lastClaim is String ? lastClaim : null;
  // `dailyDate` is written by startScoring's lifetime transaction alongside
  // dailyPoints; `lastClaimDate` is written in the separate streak tx. There
  // is a brief window where the lifetime tx commits but the streak tx is still
  // pending (or failed) — `claimedToday` should reflect "actually claimed",
  // so prefer `dailyDate` and fall back to `lastClaimDate` only when the
  // newer field isn't present (legacy accounts).
  final dailyDate = data['dailyDate'];
  final dailyDateStr = dailyDate is String ? dailyDate : null;
  final claimedToday = dailyDateStr == today || lastClaimStr == today;
  final friends = data['friends'];
  final friendCount = friends is List ? friends.length : 0;
  // Stale-streak guard mirrors StreakService.freshStreak / HomeWidgetService:
  // the server only writes `streak` on a claim, so a user who missed yesterday
  // still has a non-zero stored value until their next claim. Without this
  // guard the Remote Config audience for "30+ day streak" would carry over
  // accounts that have actually broken their streak.
  final liveStreak = freshStreak(
        storedStreak: _asInt(data['streak']),
        lastClaimDate: lastClaimStr,
        today: today,
        yesterday: yesterday,
      ) ??
      0;
  return UserPropertiesSnapshot(
    isAdmin: boolProp(isAdmin),
    hasSeenIntro: boolProp(hasSeenIntro),
    claimStreakBucket: streakBucket(liveStreak),
    lifetimePointsBucket: lifetimePointsBucket(_asInt(data['lifetimePoints'])),
    uniquePostboxesBucket:
        uniquePostboxesBucket(_asInt(data['uniquePostboxesClaimed'])),
    friendCountBucket: friendCountBucket(friendCount),
    claimedToday: boolProp(claimedToday),
    mapColor: mapColorProp(data['mapColor']),
  );
}

int _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return 0;
}
