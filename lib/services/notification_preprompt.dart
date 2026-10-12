import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/notification_service.dart';
import 'package:postbox_game/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether the post-claim pre-prompt should be shown, given whether it has
/// been answered before and the current permission. Pure, for tests.
///
/// Not when already answered, not when notifications already work, and not
/// on iOS once the system prompt has been refused (iOS never shows it again,
/// so the pre-prompt could only lead nowhere). Android reports "not yet
/// granted" as denied too, so there the pre-prompt is still worth one try.
bool shouldShowNotificationPrePrompt({
  required bool alreadyAnswered,
  required AuthorizationStatus? status,
  required bool isIOS,
}) {
  if (alreadyAnswered || status == null) return false;
  if (NotificationService.isGranted(status)) return false;
  if (isIOS && status == AuthorizationStatus.denied) return false;
  return true;
}

/// The guide's one-time ask before the system notification prompt, shown
/// after a successful claim: the first moment the player has something
/// (a streak, friends to race) that a notification would protect.
class NotificationPrePrompt {
  static const String _keyAnswered = 'notification_preprompt_answered';

  /// True once the pre-prompt has been shown in this process, so the
  /// review prompt doesn't stack a second dialog on the same moment.
  static bool shownThisSession = false;

  /// Shows the pre-prompt if [shouldShowNotificationPrePrompt] says so.
  /// Returns true when it was shown.
  static Future<bool> maybeShow(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final status = await NotificationService.permissionStatus();
    final alreadyAnswered = prefs.getBool(_keyAnswered) ?? false;
    if (status != null && NotificationService.isGranted(status)) {
      // Granted elsewhere (system settings, Route Mode): make sure the
      // token is registered, and never ask.
      unawaited(NotificationService.init());
      return false;
    }
    if (!shouldShowNotificationPrePrompt(
      alreadyAnswered: alreadyAnswered,
      status: status,
      isIOS: !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS,
    )) {
      return false;
    }
    if (!context.mounted) return false;
    shownThisSession = true;
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.notifications_active_outlined),
        title: const Text('Shall I give you a shout?'),
        content: const Text(
            "I'll tap you on the shoulder before your streak runs out, or "
            'when a friend nips ahead of you. Nothing spammy, I promise.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            style: dialogActionStyle(),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Yes please'),
          ),
        ],
      ),
    );
    await prefs.setBool(_keyAnswered, true);
    unawaited(Analytics.notificationPrePrompt(accepted: yes == true));
    if (yes == true) await NotificationService.requestAndInit();
    return true;
  }
}
