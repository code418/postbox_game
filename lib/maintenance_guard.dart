import 'package:flutter/material.dart';

import 'remote_config_service.dart';

/// Single client-side checkpoint every write entry-point routes through when
/// maintenance mode is on. Reads the Remote Config flag, shows a SnackBar in
/// James's voice if the flag is set, and returns `true` to signal "abort".
///
/// Usage:
/// ```dart
/// if (MaintenanceGuard.blocked(context)) return;
/// // ...proceed with the write
/// ```
///
/// Server-side enforcement is deliberately out of scope — this is the only
/// gate, so it must be called *before* any Firestore write, Storage upload,
/// or callable invocation that mutates state.
class MaintenanceGuard {
  MaintenanceGuard._();

  /// Returns `true` when maintenance mode is on. Side-effect: shows a SnackBar
  /// explaining what's happening using the admin-authored message. Returns
  /// `false` when the app is operating normally — callers proceed.
  ///
  /// [actionLabel] is an optional short verb (e.g. "claim", "submit report")
  /// surfaced in the toast. When omitted the toast is generic.
  static bool blocked(BuildContext context, {String? actionLabel}) {
    final service = RemoteConfigService.instance;
    if (!service.maintenanceMode) return false;
    if (context.mounted) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger != null) {
        final action = actionLabel == null ? '' : ' to $actionLabel';
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(
              "Can't$action right now, postie. ${service.maintenanceMessage}",
            ),
            duration: const Duration(seconds: 4),
          ));
      }
    }
    return true;
  }

  /// Convenience for places that need the value without a UI side-effect
  /// (e.g. silently skipping FCM token registration).
  static bool get isOn => RemoteConfigService.instance.maintenanceMode;
}
