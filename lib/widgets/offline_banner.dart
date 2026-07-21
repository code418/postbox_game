// Offline / outbox banner (ROADMAP v1.5, offline play Phases 1+3).
//
// Mounted unconditionally beside MaintenanceBanner at the top of Home. Takes
// no space while online with an empty outbox. Otherwise:
//   offline                      → "You're offline..." (+ banked count)
//   online with banked captures  → count + a manual "Send now"
// The James strip narrates flush RESULTS (home.dart listens to
// OutboxSync.lastSummary); this banner only shows standing state.

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/claim_outbox.dart';
import '../services/connectivity_service.dart';
import '../services/outbox_sync.dart';
import '../theme.dart';

class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ConnectivityService.instance.online,
      builder: (context, online, _) => ValueListenableBuilder<int>(
        valueListenable: ClaimOutbox.instance.pendingCount,
        builder: (context, pending, _) {
          if (online && pending == 0) return const SizedBox.shrink();
          final String message;
          if (!online) {
            message = pending > 0
                ? "You're offline. ${_claims(pending)} saved to post later."
                : "You're offline. Claims will be saved to post later.";
          } else {
            message = '${_claims(pending)} ready to post.';
          }
          return Material(
            color: AppColors.brandSurface,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(
                      online
                          ? Icons.schedule_send_outlined
                          : Icons.wifi_off_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        message,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          height: 1.3,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (online && pending > 0)
                      TextButton(
                        onPressed: () =>
                            unawaited(OutboxSync.instance.flushNow()),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          visualDensity: VisualDensity.compact,
                        ),
                        child: const Text('Send now'),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  static String _claims(int n) => n == 1 ? '1 claim' : '$n claims';
}
