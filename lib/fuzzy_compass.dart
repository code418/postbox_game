import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:postbox_game/theme.dart';

/// Presents nearby postbox directions in a deliberately imprecise way:
/// 8-wind sectors (N, NE, E, SE, S, SW, W, NW), vague intensity labels.
/// No exact bearings or distances — encourages exploration.
///
/// Shows unclaimed postboxes in red and claimed postboxes in grey so the
/// user can see both where they've already been and where to explore next.
class FuzzyCompass extends StatelessWidget {
  /// 16-wind counts for unclaimed postboxes (N, NNE, NE, ...). Merged to 8 sectors.
  final Map<String, int> compassCounts;

  /// 16-wind counts for postboxes already claimed today. Merged to 8 sectors.
  final Map<String, int> claimedCompassCounts;

  /// Device heading in degrees (0 = N). Optional; if null, no rotation applied.
  final double? headingDegrees;

  const FuzzyCompass({
    super.key,
    required this.compassCounts,
    this.claimedCompassCounts = const {},
    this.headingDegrees,
  });

  /// Merge 16-wind into 8-wind sectors.
  static Map<String, int> to8Sectors(Map<String, int> counts) {
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

  static String vagueLabel(int count) {
    if (count <= 0) return 'None';
    if (count <= 1) return 'One';
    if (count <= 3) return 'A few';
    return 'Several';
  }

  @override
  Widget build(BuildContext context) {
    final sectors = to8Sectors(compassCounts);
    final claimedSectors = to8Sectors(claimedCompassCounts);
    final order = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    final rotation =
        headingDegrees != null ? (headingDegrees! * pi / 180) : 0.0;

    final activeOrder = order.where((d) => (sectors[d] ?? 0) > 0).toList();
    final hasAnyClaimed = claimedSectors.values.any((v) => v > 0);

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
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                    claimedSectors: order.map((d) => claimedSectors[d] ?? 0).toList(),
                  ),
                ),
              ),
            ),
            if (hasAnyClaimed) ...[
              const SizedBox(height: AppSpacing.xs),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _LegendDot(color: postalRed.withValues(alpha: 0.7)),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    'To find',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  _LegendDot(color: Colors.grey.withValues(alpha: 0.6)),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    'Already claimed',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ],
            if (activeOrder.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: activeOrder.map((dir) {
                  final count = sectors[dir] ?? 0;
                  final label = vagueLabel(count);
                  return Chip(
                    label: Text('$dir: $label'),
                    visualDensity: VisualDensity.compact,
                  );
                }).toList(),
              ),
            ] else ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                hasAnyClaimed ? 'All found today!' : 'No postboxes in this area',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _FuzzyCompassPainter extends CustomPainter {
  final List<int> sectors;
  final List<int> claimedSectors;

  _FuzzyCompassPainter({required this.sectors, this.claimedSectors = const []});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2 - 8;
    final allCounts = [...sectors, ...claimedSectors];
    final maxCount = allCounts.isEmpty
        ? 1
        : allCounts.reduce((a, b) => a > b ? a : b).clamp(1, 999);

    for (var i = 0; i < 8; i++) {
      final startAngle = -pi / 2 + i * (2 * pi / 8);
      final sweepAngle = 2 * pi / 8;
      final count = i < sectors.length ? sectors[i] : 0;
      final claimed = i < claimedSectors.length ? claimedSectors[i] : 0;

      // Grey background: full sector for every direction so the compass ring
      // is always visible even when a direction has no postboxes.
      final bgPath = Path()
        ..moveTo(center.dx, center.dy)
        ..arcTo(Rect.fromCircle(center: center, radius: radius),
            startAngle, sweepAngle, false)
        ..close();
      canvas.drawPath(
        bgPath,
        Paint()
          ..color = Colors.grey.withValues(alpha: 0.12)
          ..style = PaintingStyle.fill,
      );

      // Draw claimed postboxes first (grey, inner layer).
      if (claimed > 0) {
        final extent = (0.3 + 0.7 * (claimed / maxCount)).clamp(0.0, 1.0);
        final r = radius * extent;
        final claimedPath = Path()
          ..moveTo(center.dx, center.dy)
          ..arcTo(Rect.fromCircle(center: center, radius: r),
              startAngle, sweepAngle, false)
          ..close();
        canvas.drawPath(
          claimedPath,
          Paint()
            ..color = Colors.grey.withValues(alpha: 0.2 + 0.3 * (claimed / maxCount))
            ..style = PaintingStyle.fill,
        );
        canvas.drawPath(
          claimedPath,
          Paint()
            ..color = Colors.grey.withValues(alpha: 0.4)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }

      // Draw unclaimed postboxes on top (red).
      if (count > 0) {
        // Red fill grows OUTWARD from center — more postboxes → larger sector.
        final extent =
            (0.3 + 0.7 * (count / maxCount)).clamp(0.0, 1.0);
        final r = radius * extent;

        final fillPath = Path()
          ..moveTo(center.dx, center.dy)
          ..arcTo(Rect.fromCircle(center: center, radius: r),
              startAngle, sweepAngle, false)
          ..close();

        canvas.drawPath(
          fillPath,
          Paint()
            ..color = postalRed.withValues(alpha: 0.25 + 0.5 * (count / maxCount))
            ..style = PaintingStyle.fill,
        );
        canvas.drawPath(
          fillPath,
          Paint()
            ..color = postalRed.withValues(alpha: 0.45)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
    }

    // North marker: red circle with white 'N'.
    // Placed just inside the arc rim (center.dy - radius + 3) so it stays
    // within the 200×200 canvas; placing it outside would clip the circle.
    final nX = center.dx;
    final nY = center.dy - radius + 3;
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
      !listEquals(old.sectors, sectors) ||
      !listEquals(old.claimedSectors, claimedSectors);
}
