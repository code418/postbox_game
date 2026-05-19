import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Renders the Postman James PNG character with lightweight animations.
///
/// - Head-bob (sine wave) while [isTalking]
/// - Spinning gold star-eyes (Canvas overlay) when [showStarEyes]
///
/// Mouth-cycle and blink animations from the old SVG version were dropped
/// when switching to the raster artwork — see lib/postman_james_svg.dart
/// for the legacy implementation.
class PostmanJames extends StatefulWidget {
  const PostmanJames({
    super.key,
    this.size = 120,
    this.isTalking = false,
    this.showStarEyes = false,
  });

  final double size;
  final bool isTalking;
  final bool showStarEyes;

  @override
  State<PostmanJames> createState() => _PostmanJamesState();
}

class _PostmanJamesState extends State<PostmanJames>
    with TickerProviderStateMixin {
  late final AnimationController _bobController;
  late final AnimationController _starController;

  @override
  void initState() {
    super.initState();

    _bobController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );

    _starController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );

    if (widget.isTalking) _bobController.repeat();
    if (widget.showStarEyes) _starController.repeat();
  }

  @override
  void didUpdateWidget(PostmanJames old) {
    super.didUpdateWidget(old);
    if (widget.isTalking && !old.isTalking) {
      _bobController.repeat();
    } else if (!widget.isTalking && old.isTalking) {
      _bobController.stop();
      _bobController.value = 0;
    }
    if (widget.showStarEyes && !old.showStarEyes) {
      _starController.repeat();
    } else if (!widget.showStarEyes && old.showStarEyes) {
      _starController.stop();
      _starController.value = 0;
    }
  }

  @override
  void dispose() {
    _bobController.dispose();
    _starController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _bobController,
      builder: (context, _) {
        final bob = math.sin(_bobController.value * 2 * math.pi) * 2.5;
        return Transform.translate(
          offset: Offset(0, bob),
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: Stack(
              children: [
                Image.asset(
                  'assets/postman_james.png',
                  width: widget.size,
                  height: widget.size,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                ),
                if (widget.showStarEyes)
                  AnimatedBuilder(
                    animation: _starController,
                    builder: (_, __) => CustomPaint(
                      size: Size(widget.size, widget.size),
                      painter: _StarEyesOverlayPainter(
                        rotation: _starController.value * 2 * math.pi,
                        pulse: 0.85 +
                            0.15 *
                                math.sin(
                                    _starController.value * 2 * math.pi),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ── Overlay painters ──────────────────────────────────────────────────────────

/// Draws animated gold 4-point star overlays over both eyes.
///
/// Eye centres are stored in PNG image coords (relative to the 314x470 source)
/// and re-projected into the letterboxed `BoxFit.contain` canvas at paint time.
class _StarEyesOverlayPainter extends CustomPainter {
  const _StarEyesOverlayPainter({
    required this.rotation,
    required this.pulse,
  });

  final double rotation;
  final double pulse;

  // Source PNG is 314x470 (aspect ~0.668). Inside a square SizedBox with
  // BoxFit.contain the image is letterboxed horizontally — _hPad is the
  // fraction of width on each side that is transparent padding.
  static const double _imgAspect = 314.0 / 470.0;
  static const double _hPad = (1 - _imgAspect) / 2;

  // Eye centres in PNG image-normalized coords (0..1 of 314x470).
  static const List<Offset> _eyeCentres = [
    Offset(0.32, 0.44), // left eye
    Offset(0.60, 0.44), // right eye
  ];
  static const double _starR = 0.065;

  @override
  void paint(Canvas canvas, Size size) {
    final gold = Paint()
      ..color = const Color(0xFFFFB400)
      ..strokeWidth = size.width * 0.013
      ..strokeCap = StrokeCap.round;
    final goldFill = Paint()..color = const Color(0xFFFFB400);

    for (final centre in _eyeCentres) {
      // Map image-normalized → letterboxed canvas-normalized.
      final canvasX = _hPad + centre.dx * _imgAspect;
      final cx = size.width * canvasX;
      final cy = size.height * centre.dy;
      final r = size.width * _starR * pulse;

      for (int i = 0; i < 4; i++) {
        final angle = rotation + math.pi / 4 * i;
        canvas.drawLine(
          Offset(cx + math.cos(angle) * r, cy + math.sin(angle) * r),
          Offset(cx - math.cos(angle) * r, cy - math.sin(angle) * r),
          gold,
        );
      }

      canvas.drawCircle(Offset(cx, cy), size.width * 0.015, goldFill);
    }
  }

  @override
  bool shouldRepaint(_StarEyesOverlayPainter old) =>
      old.rotation != rotation || old.pulse != pulse;
}
