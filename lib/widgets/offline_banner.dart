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

import '../remote_config_service.dart';
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
          // With offline claims killed the flush is refused server-side, so
          // never promise that anything will post. Already-banked captures are
          // held (they flush if the switch comes back before they expire) but
          // the copy stops committing to it and "Send now" is withdrawn.
          final killed =
              RemoteConfigService.instance.killSwitchOfflineClaims;
          final String message;
          if (!online) {
            if (killed) {
              message = pending > 0
                  ? "You're offline. ${_claims(pending)} held, but posting is paused."
                  : "You're offline. Claiming needs a connection right now.";
            } else {
              message = pending > 0
                  ? "You're offline. ${_claims(pending)} saved to post later."
                  : "You're offline. Claims will be saved to post later.";
            }
          } else {
            message = killed
                ? '${_claims(pending)} held. Posting is paused just now.'
                : '${_claims(pending)} ready to post.';
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
                      !online
                          ? Icons.wifi_off_rounded
                          : killed
                              ? Icons.pause_circle_outline
                              : Icons.schedule_send_outlined,
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
                    if (online && pending > 0 && !killed)
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
