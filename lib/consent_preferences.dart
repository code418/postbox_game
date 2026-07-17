import 'package:shared_preferences/shared_preferences.dart';

const String _keyAnalyticsDecided = 'analytics_consent_decided';
const String _keyAnalyticsGranted = 'analytics_consent_granted';
const String _keyCrashEnabled = 'crash_reporting_enabled';
const String _keyPerfEnabled = 'perf_monitoring_enabled';

/// Device-local telemetry consent state (GDPR).
///
/// SharedPreferences deliberately, not Firestore: consent is per-device SDK
/// state that must be readable before login (the intro runs unauthenticated)
/// and applied at every cold start before any Firebase collection begins.
///
/// Analytics is OPT-IN (default off until the user decides — the manifest flag
/// `firebase_analytics_collection_enabled=false` keeps the SDK silent before
/// the first runtime enable). Crash reporting and performance monitoring run
/// under legitimate interest, on by default with a Settings opt-out.
class ConsentPreferences {
  ConsentPreferences._();

  /// Whether the user has made the analytics choice (intro step or one-time
  /// prompt). Until true, the app treats analytics as not consented.
  static Future<bool> hasDecidedAnalytics() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyAnalyticsDecided) ?? false;
  }

  /// Whether the user opted in to usage analytics. Default off (opt-in).
  static Future<bool> analyticsGranted() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyAnalyticsGranted) ?? false;
  }

  /// Record the analytics choice: marks it decided and stores [granted].
  static Future<void> setAnalyticsConsent(bool granted) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAnalyticsDecided, true);
    await prefs.setBool(_keyAnalyticsGranted, granted);
  }

  /// Crash reporting toggle (legitimate interest — default on, objectable).
  static Future<bool> crashReportingEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyCrashEnabled) ?? true;
  }

  static Future<void> setCrashReportingEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyCrashEnabled, enabled);
  }

  /// Performance monitoring toggle (legitimate interest — default on).
  static Future<bool> perfMonitoringEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyPerfEnabled) ?? true;
  }

  static Future<void> setPerfMonitoringEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyPerfEnabled, enabled);
  }
}
