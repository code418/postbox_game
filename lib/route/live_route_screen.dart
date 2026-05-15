import 'package:flutter/material.dart';
import 'route_session.dart';

class LiveRouteScreen extends StatelessWidget {
  final RouteSession session;
  const LiveRouteScreen({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Live route')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Start: ${session.start.latitude.toStringAsFixed(5)}, ${session.start.longitude.toStringAsFixed(5)}'),
            Text('Destination: ${session.destination.latitude.toStringAsFixed(5)}, ${session.destination.longitude.toStringAsFixed(5)}'),
            Text('Mode: ${session.mode.name}'),
            Text('Pace: ${session.pace.name} (${session.speedKmh} km/h)'),
            Text('Corridor: ${session.corridorMetres} m'),
            Text('Detour budget: ${session.detourMinutes} min'),
            if (session.computedCount != null) ...[
              const SizedBox(height: 12),
              Text('${session.computedCount} postboxes, ${session.computedPoints} pts'),
            ],
            const SizedBox(height: 12),
            const Text('Live route UI will be built in T8.'),
          ],
        ),
      ),
    );
  }
}
