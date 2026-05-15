import 'package:flutter/material.dart';
import 'package:postbox_game/route/route_session.dart';

/// Stub screen — full implementation will be added in T7.
class RoutePreviewScreen extends StatelessWidget {
  final RouteSession session;

  const RoutePreviewScreen({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Route preview')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Start: ${session.start.latitude.toStringAsFixed(5)}, '
              '${session.start.longitude.toStringAsFixed(5)}',
            ),
            Text(
              'Destination: ${session.destination.latitude.toStringAsFixed(5)}, '
              '${session.destination.longitude.toStringAsFixed(5)}',
            ),
            const SizedBox(height: 12),
            const Text('Preview UI will be built in T7.'),
          ],
        ),
      ),
    );
  }
}
