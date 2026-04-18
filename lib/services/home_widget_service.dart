import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:postbox_game/london_date.dart';

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
      final storedStreak = (data['streak'] as num?)?.toInt() ?? 0;
      final storedPoints = (data['dailyPoints'] as num?)?.toInt() ?? 0;
      final lastClaimDate = data['lastClaimDate'] as String?;
      final dailyDate = data['dailyDate'] as String?;
      final today = todayLondon();
      final yesterday = yesterdayLondon();
      // `dailyPoints` is reset by a server-side sweep (see
      // functions/src/_leaderboardUtils.ts). Until that runs, the stored
      // value reflects the previous day's total — show 0 if the user hasn't
      // claimed anything in London-today yet. `dailyDate` is the authoritative
      // freshness marker because it's written in the same lifetime transaction
      // as `dailyPoints`; `lastClaimDate` comes from a separate streak tx and
      // has a brief ordering window. Fall back to lastClaimDate for users who
      // haven't claimed since the dailyDate field was introduced.
      final pointsAreFresh = dailyDate != null
          ? dailyDate == today
          : lastClaimDate == today;
      final todayPoints = pointsAreFresh ? storedPoints : 0;
      // Streak is only reset on the user's next claim, so a broken streak
      // would otherwise stay visible on the widget until then.
      final streak = (storedStreak > 0 &&
              (lastClaimDate == today || lastClaimDate == yesterday))
          ? storedStreak
          : 0;
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
