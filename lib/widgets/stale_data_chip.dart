// Cached-data indicator (ROADMAP v1.5, offline play Phase 1).
//
// Firestore persistence is on by default on Android/iOS, so offline reads
// silently serve the local cache — which is exactly right, but the player
// deserves to know the numbers may be stale. Mount this above a list fed by a
// snapshot and pass `snapshot.metadata.isFromCache`.
//
// The listener feeding it MUST use `snapshots(includeMetadataChanges: true)`:
// otherwise, when the server confirms a cached copy without changing it, the
// listener is never told the data is no longer from the cache, and the chip
// claims "Offline" while online.

import 'dart:async';

import 'package:flutter/material.dart';

class StaleDataChip extends StatefulWidget {
  const StaleDataChip({
    super.key,
    required this.visible,
    @visibleForTesting this.delay = defaultDelay,
  });

  /// Pass the snapshot's `metadata.isFromCache`.
  final bool visible;

  /// How long [visible] must stay true before the chip appears.
  final Duration delay;

  /// Even online, a listener's first snapshot usually comes from the local
  /// cache, with the server's confirmation a moment later. Without a grace
  /// period every cold start flashed "Offline" at a connected player.
  static const Duration defaultDelay = Duration(seconds: 3);

  @override
  State<StaleDataChip> createState() => _StaleDataChipState();
}

class _StaleDataChipState extends State<StaleDataChip> {
  Timer? _timer;
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(StaleDataChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) _sync();
  }

  void _sync() {
    _timer?.cancel();
    _timer = null;
    if (!widget.visible) {
      _shown = false;
      return;
    }
    _timer = Timer(widget.delay, () {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible || !_shown) return const SizedBox.shrink();
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
