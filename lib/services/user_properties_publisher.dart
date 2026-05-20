import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:postbox_game/admin/admin_access.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/analytics_user_properties.dart';
import 'package:postbox_game/intro_preferences.dart';

/// Reads `users/{uid}` once, resolves the admin custom claim and the
/// intro-seen flag, and pushes the resulting [UserPropertiesSnapshot] to
/// Analytics. Called on Authenticated emission and after each successful
/// claim so the leaderboard-bucket properties stay current for Remote Config
/// audience targeting.
///
/// Best-effort: every failure path logs in debug and returns. Analytics is
/// fire-and-forget; we never propagate up to UI.
Future<void> publishUserPropertiesFromFirestore(String uid) async {
  try {
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .get();
    final data = doc.data() ?? <String, dynamic>{};
    final results = await Future.wait<Object>(<Future<Object>>[
      AdminAccess.isAdmin(),
      IntroPreferences.hasSeenIntro(),
    ]);
    final snap = snapshotFromUserDoc(
      data,
      isAdmin: results[0] as bool,
      hasSeenIntro: results[1] as bool,
    );
    await Analytics.setUserProperties(snap);
  } catch (e, st) {
    debugPrint('publishUserPropertiesFromFirestore($uid) failed: $e\n$st');
  }
}
