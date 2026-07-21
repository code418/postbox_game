// Cached-data indicator (ROADMAP v1.5, offline play Phase 1).
//
// Firestore persistence is on by default on Android/iOS, so offline reads
// silently serve the local cache — which is exactly right, but the player
// deserves to know the numbers may be stale. Mount this above a list fed by a
// snapshot and pass `snapshot.metadata.isFromCache`.

import 'package:flutter/material.dart';

class StaleDataChip extends StatelessWidget {
  const StaleDataChip({super.key, required this.visible});

  /// Pass the snapshot's `metadata.isFromCache`.
  final bool visible;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_off_outlined,
                    size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  'Offline — showing saved data',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
