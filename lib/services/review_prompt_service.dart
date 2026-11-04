import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Streak lengths worth celebrating with a rating ask.
const Set<int> kReviewStreaks = {3, 7};

/// Minimum gap between rating asks. Both stores rate-limit the sheet anyway;
/// this keeps the app from spending their quota on a bad moment.
const Duration kReviewCooldown = Duration(days: 90);

/// The trigger to report for a rating ask after this claim, or null when
/// this isn't the moment. Pure, for tests.
///
/// Only from a fresh, successful claim (the caller guarantees that), only
/// when it felt good (a rare box, or a streak landmark), never on the
/// account's first day, never within [kReviewCooldown] of the last ask, and
/// never straight after another dialog in the same moment.
String? reviewPromptTrigger({
  required DateTime now,
  required DateTime? accountCreated,
  required DateTime? lastRequestedAt,
  required bool rareClaim,
  required int streak,
  required bool otherDialogShown,
}) {
  if (otherDialogShown) return null;
  if (accountCreated == null ||
      now.difference(accountCreated) < const Duration(days: 1)) {
    return null;
  }
  if (lastRequestedAt != null &&
      now.difference(lastRequestedAt) < kReviewCooldown) {
    return null;
  }
  if (rareClaim) return 'rare_claim';
  if (kReviewStreaks.contains(streak)) return 'streak';
  return null;
}

/// Asks the store for its native rating sheet at a good moment.
class ReviewPromptService {
  static const String _keyLastRequested = 'review_prompt_last_requested_ms';

  static Future<void> maybeRequest({
    required bool rareClaim,
    required int streak,
    required bool otherDialogShown,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastMs = prefs.getInt(_keyLastRequested);
      final now = DateTime.now();
      final trigger = reviewPromptTrigger(
        now: now,
        accountCreated:
            FirebaseAuth.instance.currentUser?.metadata.creationTime,
        lastRequestedAt:
            lastMs == null ? null : DateTime.fromMillisecondsSinceEpoch(lastMs),
        rareClaim: rareClaim,
        streak: streak,
        otherDialogShown: otherDialogShown,
      );
      if (trigger == null) return;
      final review = InAppReview.instance;
      // False on the web, the off-Play `auto` build without Play services,
      // and anywhere else the native sheet can't appear.
      if (!await review.isAvailable()) return;
      await prefs.setInt(_keyLastRequested, now.millisecondsSinceEpoch);
      unawaited(Analytics.reviewPromptRequested(trigger: trigger));
      await review.requestReview();
    } catch (_) {
      // A rating ask is never worth an error.
    }
  }
}
