import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Renders the Postman James SVG character with animated overlays.
///
/// Animations:
/// - Head-bob (sine wave) while [isTalking]
/// - Mouth open/close while [isTalking] (only at size >= 60)
/// - Periodic blink every 3–6 seconds
/// - Gold star-eyes when [showStarEyes]
class PostmanJamesSvg extends StatefulWidget {
  const PostmanJamesSvg({
    super.key,
    this.size = 120,
    this.isTalking = false,
    this.showStarEyes = false,
  });

  final double size;
  final bool isTalking;
  final bool showStarEyes;

  @override
  State<PostmanJamesSvg> createState() => _PostmanJamesSvgState();
}

class _PostmanJamesSvgState extends State<PostmanJamesSvg>
    with TickerProviderStateMixin {
  late final AnimationController _bobController;
  late final AnimationController _mouthController;
  late final AnimationController _blinkController;
  late final Animation<double> _mouthAnim;
  Timer? _blinkTimer;

  @override
  void initState() {
    super.initState();

    _bobController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );

    _mouthController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _mouthAnim = CurvedAnimation(
      parent: _mouthController,
      curve: Curves.easeInOut,
    );

    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );

    if (widget.isTalking) _startTalkingAnimations();
    _scheduleBlink();
  }

  void _startTalkingAnimations() {
    _bobController.repeat();
    _mouthController.repeat(reverse: true);
  }

  void _stopTalkingAnimations() {
    _bobController.stop();
    _bobController.value = 0;
    _mouthController.stop();
    _mouthController.value = 0;
  }

  void _scheduleBlink() {
    final delayMs = 3000 + math.Random().nextInt(3000);
    _blinkTimer = Timer(Duration(milliseconds: delayMs), () async {
      if (!mounted) return;
      await _blinkController.forward();
      if (!mounted) return;
      await _blinkController.reverse();
      if (mounted) _scheduleBlink();
    });
  }

  @override
  void didUpdateWidget(PostmanJamesSvg old) {
    super.didUpdateWidget(old);
    if (widget.isTalking && !old.isTalking) {
      _startTalkingAnimations();
    } else if (!widget.isTalking && old.isTalking) {
      _stopTalkingAnimations();
    }
  }

  @override
  void dispose() {
    _blinkTimer?.cancel();
    _bobController.dispose();
    _mouthController.dispose();
    _blinkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showMouth = widget.isTalking && widget.size >= 60;

    return AnimatedBuilder(
      animation: Listenable.merge([_bobController, _mouthController]),
      builder: (context, child) {
        final bob =
            math.sin(_bobController.value * 2 * math.pi) * 2.5;
        return Transform.translate(
          offset: Offset(0, bob),
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: Stack(
              children: [
                SvgPicture.asset(
                  'assets/postman_james.svg',
                  width: widget.size,
                  height: widget.size,
                  fit: BoxFit.contain,
                ),
                if (showMouth)
                  CustomPaint(
                    size: Size(widget.size, widget.size),
                    painter:
                        _MouthOverlayPainter(openFraction: _mouthAnim.value),
                  ),
                AnimatedBuilder(
                  animation: _blinkController,
                  builder: (_, __) => CustomPaint(
                    size: Size(widget.size, widget.size),
                    painter: _BlinkOverlayPainter(
                      closeFraction: _blinkController.value,
                    ),
                  ),
                ),
                if (widget.showStarEyes)
                  CustomPaint(
                    size: Size(widget.size, widget.size),
                    painter: const _StarEyesOverlayPainter(),
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

/// Hides the static SVG smile and draws an animated open/close mouth.
///
/// Proportional coordinates are based on SVG path analysis (viewBox 10 15 192 243).
/// Tune [_cx], [_cy], [_skinR] after first visual run if needed.
class _MouthOverlayPainter extends CustomPainter {
  const _MouthOverlayPainter({required this.openFraction});
  final double openFraction;

  static const double _cx = 0.36;
  static const double _cy = 0.64;
  static const double _halfW = 0.085;
  static const double _skinR = 0.09;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width * _cx;
    final cy = size.height * _cy;
    final hw = size.width * _halfW;

    // Erase the SVG's static smile with a skin-coloured circle.
    final eraser = Paint()..color = const Color(0xFFFFD5B0);
    canvas.drawCircle(Offset(cx, cy), size.width * _skinR, eraser);

    final openH = size.height * 0.03 * openFraction;
    if (openH < 0.5) return;

    // Filled oval for open mouth (dark red interior).
    final mouthPaint = Paint()
      ..color = const Color(0xFF8B2500)
      ..style = PaintingStyle.fill;
    final rect = Rect.fromCenter(
      center: Offset(cx, cy + openH * 0.5),
      width: hw * 2,
      height: openH * 2,
    );
    canvas.drawOval(rect, mouthPaint);

    // White teeth strip when more than half open.
    if (openFraction > 0.5) {
      canvas.drawRect(
        Rect.fromLTRB(cx - hw * 0.7, cy, cx + hw * 0.7, cy + openH * 0.4),
        Paint()..color = Colors.white,
      );
    }
  }

  @override
  bool shouldRepaint(_MouthOverlayPainter old) =>
      old.openFraction != openFraction;
}

/// Paints skin-coloured lids over both eyes to simulate a blink.
class _BlinkOverlayPainter extends CustomPainter {
  const _BlinkOverlayPainter({required this.closeFraction});
  final double closeFraction;

  static const List<Offset> _eyeCentres = [
    Offset(0.33, 0.34), // left eye
    Offset(0.56, 0.34), // right eye
  ];
  static const double _eyeHalfW = 0.11;
  static const double _eyeHalfH = 0.07;

  @override
  void paint(Canvas canvas, Size size) {
    if (closeFraction < 0.05) return;
    final paint = Paint()..color = const Color(0xFFFFD5B0);
    for (final centre in _eyeCentres) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(size.width * centre.dx, size.height * centre.dy),
          width: size.width * _eyeHalfW * 2,
          height: size.height * _eyeHalfH * 2 * closeFraction,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BlinkOverlayPainter old) =>
      old.closeFraction != closeFraction;
}

/// Draws gold 4-point star overlays over both eyes.
class _StarEyesOverlayPainter extends CustomPainter {
  const _StarEyesOverlayPainter();

  static const List<Offset> _eyeCentres = [
    Offset(0.33, 0.34),
    Offset(0.56, 0.34),
  ];
  static const double _starR = 0.065;

  @override
  void paint(Canvas canvas, Size size) {
    final eraser = Paint()..color = Colors.white;
    final gold = Paint()
      ..color = const Color(0xFFFFB400)
      ..strokeWidth = size.width * 0.012
      ..strokeCap = StrokeCap.round;
    final goldFill = Paint()..color = const Color(0xFFFFB400);

    for (final centre in _eyeCentres) {
      final cx = size.width * centre.dx;
      final cy = size.height * centre.dy;
      final r = size.width * _starR;

      // Erase iris.
      canvas.drawCircle(Offset(cx, cy), r, eraser);

      // 4-point star.
      for (int i = 0; i < 4; i++) {
        final angle = math.pi / 4 * i;
        canvas.drawLine(
          Offset(cx + math.cos(angle) * r, cy + math.sin(angle) * r),
          Offset(cx - math.cos(angle) * r, cy - math.sin(angle) * r),
          gold,
        );
      }

      // Centre dot.
      canvas.drawCircle(Offset(cx, cy), size.width * 0.015, goldFill);
    }
  }

  @override
  bool shouldRepaint(_StarEyesOverlayPainter _) => false;
}
