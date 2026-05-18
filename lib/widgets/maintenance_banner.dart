import 'package:flutter/material.dart';

import '../remote_config_service.dart';
import '../theme.dart';

/// Persistent strip mounted at the top of [Home] (and the login screen) that
/// surfaces the admin-authored maintenance message whenever the
/// `maintenance_mode` Remote Config flag is on. Rebuilds via
/// [RemoteConfigService.maintenanceModeListenable] so a flag flipped via the
/// Firebase console (push update) or admin force-refresh appears without an
/// app restart.
///
/// Takes no space when the flag is off — safe to mount unconditionally above
/// existing screen content.
class MaintenanceBanner extends StatelessWidget {
  const MaintenanceBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: RemoteConfigService.instance.maintenanceModeListenable,
      builder: (context, on, _) {
        if (!on) return const SizedBox.shrink();
        final service = RemoteConfigService.instance;
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
                  const Icon(
                    Icons.build_circle_outlined,
                    color: Colors.white,
                    size: 20,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      service.maintenanceMessage,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        height: 1.3,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
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
