import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:postbox_game/theme.dart';

/// Presents nearby postbox directions in a deliberately imprecise way:
/// 8-wind sectors (N, NE, E, SE, S, SW, W, NW), vague intensity labels.
/// No exact bearings or distances — encourages exploration.
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

  /// Merge 16-wind into 8-wind.
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

  static String _vagueLabel(int count) {
    if (count <= 0) return 'None';
    if (count <= 1) return 'One';
    if (count <= 3) return 'A few';
    return 'Several';
  }

  @override
  Widget build(BuildContext context) {
    final sectors = _to8Sectors(compassCounts);
    final order = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    final rotation =
        headingDegrees != null ? (headingDegrees! * pi / 180) : 0.0;

    // Only show chips for non-zero sectors
    final activeOrder = order.where((d) => (sectors[d] ?? 0) > 0).toList();

    return Card(
      margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm - 2),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Rough direction',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            Text(
              'No exact locations shown',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.grey.shade500),
            ),
            const SizedBox(height: AppSpacing.md),
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
            if (activeOrder.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: activeOrder.map((dir) {
                  final count = sectors[dir] ?? 0;
                  final label = _vagueLabel(count);
                  return Chip(
                    label: Text('$dir: $label'),
                    visualDensity: VisualDensity.compact,
                  );
                }).toList(),
              ),
            ] else ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                'No postboxes in this area',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.grey),
              ),
            ],
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
    final maxCount = sectors.isEmpty
        ? 1
        : sectors.reduce((a, b) => a > b ? a : b).clamp(1, 999);

    for (var i = 0; i < 8; i++) {
      final startAngle = -pi / 2 + i * (2 * pi / 8);
      final sweepAngle = 2 * pi / 8;
      final count = i < sectors.length ? sectors[i] : 0;
      final extent =
          count <= 0 ? 0.0 : (0.3 + 0.7 * (count / maxCount)).clamp(0.0, 1.0);
      final r = radius * extent;

      final path = Path()
        ..moveTo(center.dx, center.dy)
        ..arcTo(Rect.fromCircle(center: center, radius: radius), startAngle,
            sweepAngle, false)
        ..lineTo(center.dx + cos(startAngle + sweepAngle) * r,
            center.dy + sin(startAngle + sweepAngle) * r)
        ..arcTo(Rect.fromCircle(center: center, radius: r),
            startAngle + sweepAngle, -sweepAngle, false)
        ..close();

      canvas.drawPath(
        path,
        Paint()
          ..color = count > 0
              ? postalRed.withValues(alpha:0.25 + 0.5 * (count / maxCount))
              : Colors.grey.withValues(alpha:0.12)
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = postalRed.withValues(alpha:0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }

    // North marker: red circle with white 'N'
    final nX = center.dx;
    final nY = center.dy - radius - 10;
    canvas.drawCircle(
        Offset(nX, nY), 9, Paint()..color = postalRed);

    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      textAlign: TextAlign.center,
      fontSize: 10,
      fontWeight: FontWeight.bold,
    ))
      ..pushStyle(ui.TextStyle(color: Colors.white, fontWeight: FontWeight.bold))
      ..addText('N');
    final para = builder.build()
      ..layout(const ui.ParagraphConstraints(width: 18));
    canvas.drawParagraph(para, Offset(nX - 9, nY - 6));
  }

  @override
  bool shouldRepaint(covariant _FuzzyCompassPainter old) =>
      old.sectors != sectors;
}
