import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';

/// Thin typed wrapper around [FirebaseAnalytics].
///
/// All methods are static and fire-and-forget — errors are logged in debug
/// mode but never propagated to callers.
class Analytics {
  Analytics._();

  static final FirebaseAnalytics _fa = FirebaseAnalytics.instance;

  static FirebaseAnalyticsObserver get observer =>
      FirebaseAnalyticsObserver(analytics: _fa);

  // ---------------------------------------------------------------------------
  // Scan events
  // ---------------------------------------------------------------------------

  /// User tapped "Scan for postboxes nearby".
  static Future<void> scanStarted() => _log('scan_started');

  /// Scan returned results.
  static Future<void> scanComplete({
    required int count,
    required int claimedToday,
    required int minPoints,
    required int maxPoints,
  }) =>
      _log('scan_complete', {
        'postbox_count': count,
        'claimed_today': claimedToday,
        'min_points': minPoints,
        'max_points': maxPoints,
      });

  /// Scan returned zero postboxes in range.
  static Future<void> scanEmpty() => _log('scan_empty');

  // ---------------------------------------------------------------------------
  // Quiz events
  // ---------------------------------------------------------------------------

  /// Quiz screen shown for the given cipher.
  static Future<void> quizStarted({required String cipher}) =>
      _log('quiz_started', {'cipher': cipher});

  /// User picked the correct cipher.
  static Future<void> quizCorrect({required String cipher}) =>
      _log('quiz_correct', {'cipher': cipher});

  /// User picked a wrong cipher.
  static Future<void> quizIncorrect({
    required String correctCipher,
    required String selectedCipher,
  }) =>
      _log('quiz_incorrect', {
        'correct_cipher': correctCipher,
        'selected_cipher': selectedCipher,
      });

  // ---------------------------------------------------------------------------
  // Claim events
  // ---------------------------------------------------------------------------

  /// Claim succeeded.
  static Future<void> claimSuccess({
    required int pointsEarned,
    required int claimedCount,
  }) =>
      _log('claim_success', {
        'points_earned': pointsEarned,
        'claimed_count': claimedCount,
      });

  /// Claim failed for a known reason.
  static Future<void> claimFailed({required String reason}) =>
      _log('claim_failed', {'reason': reason});

  // ---------------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------------

  /// Standard Firebase Analytics login event.
  /// [method] is e.g. 'email' or 'google'.
  static Future<void> login({required String method}) =>
      _fa.logLogin(loginMethod: method);

  /// Login attempt that ended in failure.
  static Future<void> loginFailed({
    required String method,
    required String errorCode,
  }) =>
      _log('login_failed', {'method': method, 'error_code': errorCode});

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  /// Bottom-nav tab selected (0=Nearby, 1=Claim, 2=Scores, 3=Friends).
  static Future<void> tabSelected({required int index, required String name}) =>
      _log('tab_selected', {'tab_index': index, 'tab_name': name});

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  static Future<void> _log(String name, [Map<String, Object>? params]) async {
    try {
      await _fa.logEvent(name: name, parameters: params);
    } catch (e) {
      debugPrint('Analytics._log($name): $e');
    }
  }
}
