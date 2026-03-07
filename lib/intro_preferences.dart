import 'package:shared_preferences/shared_preferences.dart';

const String _keyIntroSeen = 'intro_seen';

/// Persists whether the user has completed the first-run intro.
class IntroPreferences {
  static Future<bool> hasSeenIntro() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyIntroSeen) ?? false;
  }

  static Future<void> setIntroSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyIntroSeen, true);
  }
}
