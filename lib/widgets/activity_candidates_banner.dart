import 'dart:async';

import 'package:flutter/material.dart';
import 'package:postbox_game/activity/activity_claims_screen.dart';
import 'package:postbox_game/services/activity_claims_service.dart';
import 'package:postbox_game/theme.dart';

/// "3 unclaimed postboxes on your recent workouts" — shown under the offline
/// banner on Home while workout candidates are waiting. James can't carry an
/// action (tapping his strip dismisses it), hence a banner of its own.
class ActivityCandidatesBanner extends StatelessWidget {
  const ActivityCandidatesBanner({super.key, this.service});

  final ActivityClaimsService? service;

  @override
  Widget build(BuildContext context) {
    final svc = service ?? ActivityClaimsService.instance;
    return ValueListenableBuilder<int>(
      valueListenable: svc.bannerCount,
      builder: (context, count, _) {
        if (count <= 0) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Material(
          color: scheme.secondaryContainer,
          child: SafeArea(
            top: false,
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
              child: Row(
                children: [
                  Icon(Icons.directions_run, color: scheme.onSecondaryContainer),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      count == 1
                          ? '1 unclaimed postbox on your recent workouts'
                          : '$count unclaimed postboxes on your recent workouts',
                      style: TextStyle(color: scheme.onSecondaryContainer),
                    ),
                  ),
                  TextButton(
                    onPressed: () => unawaited(svc.snoozeBanner()),
                    child: const Text('Not now'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => ActivityClaimsScreen(service: service)),
                    ).then((_) => svc.refreshBanner()),
                    child: const Text('Claim'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
