import 'package:flutter/foundation.dart';
import 'package:postbox_game/deep_links.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds a postbox link until a signed-in Home can act on it.
///
/// The phone app needs a sign-in before play, so a link opened by someone
/// who has just installed the app has to survive the intro and sign-up. The
/// link is parked here (persisted, so it survives the app being killed
/// mid-registration) and Home takes it once it mounts. The same shape as
/// `PendingInviteStore`, with a much shorter shelf life: following a postbox
/// link means being near that box now.
class PendingPostboxLinkStore {
  static const String _keyCode = 'pending_postbox_link_code';
  static const String _keySrc = 'pending_postbox_link_src';
  static const String _keySavedAt = 'pending_postbox_link_saved_at';

  /// Long enough to install, sign up and come back to the box; short enough
  /// that a link opened yesterday doesn't open a claim screen today.
  static const Duration maxAge = Duration(hours: 1);

  /// Bumped on every [save] so an already-mounted Home can react to a link
  /// opened while the app was running.
  static final ValueNotifier<int> signal = ValueNotifier<int>(0);

  static Future<void> save(PostboxLink link, {DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCode, link.code);
    if (link.src == null) {
      await prefs.remove(_keySrc);
    } else {
      await prefs.setString(_keySrc, link.src!);
    }
    await prefs.setInt(
        _keySavedAt, (now ?? DateTime.now()).millisecondsSinceEpoch);
    signal.value++;
  }

  /// Returns the parked link and clears it, so each link is acted on once.
  /// Null when nothing is parked or it is older than [maxAge].
  static Future<PostboxLink?> take({DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_keyCode);
    final src = prefs.getString(_keySrc);
    final savedAt = prefs.getInt(_keySavedAt);
    await prefs.remove(_keyCode);
    await prefs.remove(_keySrc);
    await prefs.remove(_keySavedAt);
    if (code == null || savedAt == null) return null;
    final age = (now ?? DateTime.now())
        .difference(DateTime.fromMillisecondsSinceEpoch(savedAt));
    if (age > maxAge) return null;
    return PostboxLink(code, src: src);
  }
}
