import 'package:flutter/material.dart';

import 'route_session.dart';

/// Shown when the user arrives at the destination (or via the End route flow).
///
/// Currently a stub — the full completion UI will be built in T9.
class RouteCompletionScreen extends StatelessWidget {
  final RouteSession session;
  final int pointsEarned;
  final int claimedCount;
  final int walkSeconds;

  const RouteCompletionScreen({
    super.key,
    required this.session,
    this.pointsEarned = 0,
    this.claimedCount = 0,
    this.walkSeconds = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Route complete')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Points earned: $pointsEarned'),
            Text('Postboxes claimed: $claimedCount'),
            Text(
                'Walking time: ${(walkSeconds / 60).toStringAsFixed(1)} min'),
            const SizedBox(height: 12),
            const Text('Completion UI will be built in T9.'),
            const Spacer(),
            FilledButton(
              onPressed: () =>
                  Navigator.popUntil(context, (r) => r.isFirst),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}
