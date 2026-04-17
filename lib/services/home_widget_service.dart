import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

/// Pushes streak + today's points to the native Android home-screen widget.
///
/// Designed to be injected (mirrors [StreakService]) so tests can replace the
/// Firestore/Auth backends. The widget itself is implemented in
/// `android/app/src/main/kotlin/.../PostboxWidgetProvider.kt`; this service is
/// the Flutter-side data bridge.
class HomeWidgetService {
  HomeWidgetService({FirebaseFirestore? firestore, FirebaseAuth? auth})
      : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  static const String appGroupId = 'PostboxGameWidget';
  static const String androidProviderName = 'PostboxWidgetProvider';

  static const String keySignedIn = 'signedIn';
  static const String keyStreak = 'streak';
  static const String keyTodayPoints = 'todayPoints';

  /// Called once from `main()` before the first refresh. No-op on platforms
  /// where the `home_widget` plugin isn't registered (web, desktop).
  static Future<void> init() async {
    try {
      await HomeWidget.setAppGroupId(appGroupId);
    } catch (e) {
      debugPrint('HomeWidgetService.init skipped: $e');
    }
  }

  /// Writes the current auth + streak + today's points into the widget's
  /// SharedPreferences store and asks Android to redraw. Silent no-op on
  /// platforms where the home_widget channel isn't wired (iOS without a
  /// widget extension, desktop, web).
  Future<void> refresh() async {
    try {
      final uid = _auth.currentUser?.uid;
      if (uid == null) {
        await _saveAll(signedIn: false, streak: 0, todayPoints: 0);
        await _pushUpdate();
        return;
      }
      final snap = await _firestore.collection('users').doc(uid).get();
      final data = snap.data() ?? const <String, dynamic>{};
      final streak = (data['streak'] as num?)?.toInt() ?? 0;
      final storedPoints = (data['dailyPoints'] as num?)?.toInt() ?? 0;
      final lastClaimDate = data['lastClaimDate'] as String?;
      // `dailyPoints` is reset by a server-side sweep (see
      // functions/src/_leaderboardUtils.ts). Until that runs, the stored
      // value reflects the previous day's total — show 0 if the user hasn't
      // claimed anything in London-today yet.
      final todayPoints = lastClaimDate == _todayLondon() ? storedPoints : 0;
      await _saveAll(signedIn: true, streak: streak, todayPoints: todayPoints);
      await _pushUpdate();
    } catch (e) {
      // Widget refresh must never break the app.
      debugPrint('HomeWidgetService.refresh failed: $e');
    }
  }

  Future<void> _saveAll({
    required bool signedIn,
    required int streak,
    required int todayPoints,
  }) async {
    await HomeWidget.saveWidgetData<bool>(keySignedIn, signedIn);
    await HomeWidget.saveWidgetData<int>(keyStreak, streak);
    await HomeWidget.saveWidgetData<int>(keyTodayPoints, todayPoints);
  }

  Future<void> _pushUpdate() async {
    await HomeWidget.updateWidget(androidName: androidProviderName);
  }
}

/// Returns today's date in London (Europe/London) as `YYYY-MM-DD`. Matches
/// `functions/src/_dateUtils.ts::getTodayLondon` so a widget value written by
/// this service compares equal to the `lastClaimDate` set by `startScoring`.
String _todayLondon() {
  // Europe/London is UTC+0 in GMT and UTC+1 in BST. BST runs from the last
  // Sunday of March 01:00 UTC to the last Sunday of October 01:00 UTC.
  final nowUtc = DateTime.now().toUtc();
  final offset = _isBst(nowUtc) ? const Duration(hours: 1) : Duration.zero;
  final london = nowUtc.add(offset);
  final y = london.year.toString().padLeft(4, '0');
  final m = london.month.toString().padLeft(2, '0');
  final d = london.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

bool _isBst(DateTime utc) {
  final year = utc.year;
  final bstStart = _lastSundayOfMonthUtcAt01(year, 3);
  final bstEnd = _lastSundayOfMonthUtcAt01(year, 10);
  return !utc.isBefore(bstStart) && utc.isBefore(bstEnd);
}

DateTime _lastSundayOfMonthUtcAt01(int year, int month) {
  final lastDay = DateTime.utc(year, month + 1, 0);
  final offsetToSunday = lastDay.weekday % 7; // Mon=1..Sun=7 → Sun becomes 0
  final sunday = lastDay.subtract(Duration(days: offsetToSunday));
  return DateTime.utc(sunday.year, sunday.month, sunday.day, 1);
}
