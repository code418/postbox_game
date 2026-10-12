import 'dart:async';

import 'package:flutter/material.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/maintenance_guard.dart';
import 'package:postbox_game/services/invite_service.dart';
import 'package:postbox_game/theme.dart';

/// Looks up an invite [code], asks the player to confirm, and makes the two
/// players friends both ways. Returns true when a new friendship was made.
///
/// Shared by the invite-link path (Home picks up a parked code) and the
/// Friends tab's add field. Every outcome ends in one snackbar so the
/// player always knows what happened to the link they tapped.
Future<bool> runInviteAcceptFlow(BuildContext context, String code) async {
  if (MaintenanceGuard.blocked(context, actionLabel: 'add a friend')) {
    return false;
  }
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) =>
      messenger.showSnackBar(SnackBar(content: Text(text)));

  final InvitePreview preview;
  try {
    preview = await InviteService.preview(code);
  } on InviteException catch (e) {
    unawaited(Analytics.inviteAccepted(result: e.analyticsResult));
    say(e.message);
    return false;
  }
  if (preview.alreadyFriends) {
    unawaited(Analytics.inviteAccepted(result: 'already_friends'));
    say("You're already friends with ${preview.inviterName}.");
    return false;
  }
  if (!context.mounted) return false;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Add ${preview.inviterName}?'),
      content: Text(
          '${preview.inviterName} invited you to play. Become friends to '
          "see each other's finds and compete on the friends leaderboard."),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          style: dialogActionStyle(),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Add friend'),
        ),
      ],
    ),
  );
  if (confirmed != true) {
    unawaited(Analytics.inviteAccepted(result: 'declined'));
    return false;
  }

  try {
    final accepted = await InviteService.accept(code);
    unawaited(Analytics.inviteAccepted(
        result: 'accepted', referral: accepted.referralRecorded));
    say(accepted.inviterListFull
        ? "${accepted.inviterName} is now your friend. Their list is full, "
            "so they'll need to make room to add you back."
        : 'You and ${accepted.inviterName} are now friends.');
    return true;
  } on InviteException catch (e) {
    unawaited(Analytics.inviteAccepted(result: e.analyticsResult));
    say(e.message);
    return false;
  }
}
