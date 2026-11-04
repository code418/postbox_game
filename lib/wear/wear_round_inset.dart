import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Confines [child] to the largest square inscribed in the round display.
///
/// Flutter lays Wear pages out against the full square framebuffer, but a
/// round watch only shows the inscribed circle: anything laid out near a
/// corner, or wide content near the top or bottom where the chord is
/// narrow, is cut off by the bezel. (Play rejected the app for exactly this —
/// the login page's error line was chopped at both edges.) This is the
/// Flutter equivalent of androidx.wear's `BoxInsetLayout` with
/// `layout_boxedEdges="all"`: content inside a [WearRoundInset] can never be
/// clipped by a round screen, wherever it sits.
///
/// Assumes a round display. Every Wear OS 3+ watch on sale is round, and on
/// a square one the only effect is a slightly larger margin — so no plugin
/// is pulled in just to detect the shape.
class WearRoundInset extends StatelessWidget {
  const WearRoundInset({super.key, required this.child});

  final Widget child;

  /// Per-side inset as a fraction of the diameter: (1 - 1/√2) / 2. Turns the
  /// circle's bounding square into its inscribed square (androidx
  /// `BoxInsetLayout.FACTOR`). ~28 dp on a 192 dp watch, leaving ~136 dp.
  static const double insetFactor = (1 - math.sqrt1_2) / 2;

  static double insetFor(Size size) => size.shortestSide * insetFactor;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Padding(
        padding: EdgeInsets.all(insetFor(constraints.biggest)),
        child: child,
      ),
    );
  }
}
