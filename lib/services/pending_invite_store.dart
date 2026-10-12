import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds an invite code from a link until a signed-in Home can act on it.
///
/// Invite links mostly reach people who aren't players yet, so the link is
/// usually opened before the intro, sign-up and consent have happened. The
/// code is parked here (persisted, so it also survives the app being killed
/// mid-registration) and Home takes it once it mounts.
class PendingInviteStore {
  static const String _keyCode = 'pending_invite_code';
  static const String _keySavedAt = 'pending_invite_saved_at';

  /// How long a parked invite stays usable. Long enough to install, sign up
  /// and come back over a weekend; short enough that a stale code doesn't
  /// surprise someone who never finished signing up.
  static const Duration maxAge = Duration(days: 14);

  /// Bumped on every [save] so an already-mounted Home can react to a link
  /// opened while the app was running.
  static final ValueNotifier<int> signal = ValueNotifier<int>(0);

  static Future<void> save(String code, {DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCode, code);
    await prefs.setInt(
        _keySavedAt, (now ?? DateTime.now()).millisecondsSinceEpoch);
    signal.value++;
  }

  /// Returns the parked code and clears it, so each link is acted on once.
  /// Null when nothing is parked or it is older than [maxAge].
  static Future<String?> take({DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_keyCode);
    final savedAt = prefs.getInt(_keySavedAt);
    await prefs.remove(_keyCode);
    await prefs.remove(_keySavedAt);
    if (code == null || savedAt == null) return null;
    final age = (now ?? DateTime.now())
        .difference(DateTime.fromMillisecondsSinceEpoch(savedAt));
    return age > maxAge ? null : code;
  }
}
