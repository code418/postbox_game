import 'dart:math';
import 'package:flutter/material.dart';

/// Presents nearby postbox directions in a deliberately imprecise way:
/// 8-wind sectors (N, NE, E, SE, S, SW, W, NW), vague intensity (none / some / several),
/// no exact bearings or distances. Encourages exploration without turn-by-turn navigation.
/// Claimed vs unclaimed would require backend to return separate counts per sector.
class FuzzyCompass extends StatelessWidget {
  /// 16-wind counts from backend (N, NNE, NE, ...). Will be merged to 8 sectors.
  final Map<String, int> compassCounts;

  /// Device heading in degrees (0 = N). Optional; if null, no rotation applied.
  final double? headingDegrees;

  const FuzzyCompass({
    Key? key,
    required this.compassCounts,
    this.headingDegrees,
  }) : super(key: key);

  /// Merge 16-wind into 8-wind: N, NE, E, SE, S, SW, W, NW (each 16-wind counted once).
  static Map<String, int> _to8Sectors(Map<String, int> counts) {
    final out = <String, int>{};
    final pairs = [
      ('N', ['N', 'NNE']),
      ('NE', ['NE', 'ENE']),
      ('E', ['E', 'ESE']),
      ('SE', ['SE', 'SSE']),
      ('S', ['S', 'SSW']),
      ('SW', ['SW', 'WSW']),
      ('W', ['W', 'WNW']),
      ('NW', ['NW', 'NNW']),
    ];
    for (final e in pairs) {
      out[e.$1] = e.$2.fold<int>(0, (s, d) => s + (counts[d] ?? 0));
    }
    return out;
  }

  /// Vague label to avoid exact counts: none / a few / some / several.
  static String _vagueLabel(int count) {
    if (count <= 0) return 'None';
    if (count <= 2) return 'A few';
    if (count <= 5) return 'Some';
    return 'Several';
  }

  @override
  Widget build(BuildContext context) {
    final sectors = _to8Sectors(compassCounts);
    final order = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    final rotation = headingDegrees != null
        ? (headingDegrees! * pi / 180)
        : 0.0;

    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Rough direction (no exact locations)',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: 200,
              height: 200,
              child: Transform.rotate(
                angle: -rotation,
                child: CustomPaint(
                  painter: _FuzzyCompassPainter(
                    sectors: order.map((d) => sectors[d] ?? 0).toList(),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: order.map((dir) {
                final count = sectors[dir] ?? 0;
                final label = _vagueLabel(count);
                return Chip(
                  label: Text('$dir: $label'),
                  visualDensity: VisualDensity.compact,
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _FuzzyCompassPainter extends CustomPainter {
  final List<int> sectors;

  _FuzzyCompassPainter({required this.sectors});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2 - 8;
    final maxCount = sectors.isEmpty ? 1 : sectors.reduce((a, b) => a > b ? a : b).clamp(1, 999);

    for (var i = 0; i < 8; i++) {
      final startAngle = -pi / 2 + i * (2 * pi / 8);
      final sweepAngle = 2 * pi / 8;
      final count = i < sectors.length ? sectors[i] : 0;
      final extent = count <= 0 ? 0.0 : (0.3 + 0.7 * (count / maxCount)).clamp(0.0, 1.0);
      final r = radius * extent;
      final path = Path()
        ..moveTo(center.dx, center.dy)
        ..arcTo(Rect.fromCircle(center: center, radius: radius), startAngle, sweepAngle, false)
        ..lineTo(center.dx + cos(startAngle + sweepAngle) * r, center.dy + sin(startAngle + sweepAngle) * r)
        ..arcTo(Rect.fromCircle(center: center, radius: r), startAngle + sweepAngle, -sweepAngle, false)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = count > 0 ? Colors.blue.withValues(alpha: 0.3 + 0.5 * (count / maxCount)) : Colors.grey.withValues(alpha: 0.2)
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.blueGrey
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    // N marker
    canvas.drawCircle(Offset(center.dx, center.dy - radius - 4), 4, Paint()..color = Colors.black);
  }

  @override
  bool shouldRepaint(covariant _FuzzyCompassPainter old) => old.sectors != sectors;
}
