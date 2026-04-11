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
/// - Gold spinning star-eyes when [showStarEyes]
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
  late final AnimationController _starController;
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

    _starController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );

    if (widget.isTalking) _startTalkingAnimations();
    if (widget.showStarEyes) _starController.repeat();
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
      // Occasionally double-blink.
      if (mounted && math.Random().nextDouble() < 0.2) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        if (!mounted) return;
        await _blinkController.forward();
        if (!mounted) return;
        await _blinkController.reverse();
      }
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
    if (widget.showStarEyes && !old.showStarEyes) {
      _starController.repeat();
    } else if (!widget.showStarEyes && old.showStarEyes) {
      _starController.stop();
      _starController.value = 0;
    }
  }

  @override
  void dispose() {
    _blinkTimer?.cancel();
    _bobController.dispose();
    _mouthController.dispose();
    _blinkController.dispose();
    _starController.dispose();
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
                  AnimatedBuilder(
                    animation: _starController,
                    builder: (_, __) => CustomPaint(
                      size: Size(widget.size, widget.size),
                      painter: _StarEyesOverlayPainter(
                        rotation: _starController.value * 2 * math.pi,
                        pulse: 0.85 +
                            0.15 *
                                math.sin(
                                    _starController.value * 2 * math.pi * 2),
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

/// Hides the static SVG smile and draws an animated open/close mouth.
///
/// Proportional coordinates are derived from SVG path analysis
/// (viewBox 10 15 192 243, layer1 matrix(1.0819613,0,0,1.0819613,-6.6485319,-2.8901256)).
/// Mouth path8 spans SVG-local x≈63–97, y≈163–177 → normalised cx≈0.37, cy≈0.68.
class _MouthOverlayPainter extends CustomPainter {
  const _MouthOverlayPainter({required this.openFraction});
  final double openFraction;

  // SVG skin fill is #ffaaaa.
  static const Color _skinColour = Color(0xFFFFAAAA);

  static const double _cx = 0.37;
  static const double _cy = 0.68;
  static const double _halfW = 0.095;
  static const double _skinR = 0.095;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width * _cx;
    final cy = size.height * _cy;
    final hw = size.width * _halfW;

    // Erase the SVG's static smile with a skin-coloured oval.
    final eraser = Paint()..color = _skinColour;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx, cy),
        width: size.width * _skinR * 2.2,
        height: size.height * _skinR * 0.7,
      ),
      eraser,
    );

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
///
/// Eye centres derived from SVG eyeball bounds:
/// - Left eye (path3): SVG-local x≈62–88, y≈80–116 → normalised (0.33, 0.36)
/// - Right eye (path4): SVG-local x≈97–136, y≈83–118 → normalised (0.57, 0.37)
class _BlinkOverlayPainter extends CustomPainter {
  const _BlinkOverlayPainter({required this.closeFraction});
  final double closeFraction;

  // SVG skin fill is #ffaaaa.
  static const Color _skinColour = Color(0xFFFFAAAA);

  static const List<Offset> _eyeCentres = [
    Offset(0.33, 0.36), // left eye
    Offset(0.57, 0.37), // right eye
  ];
  static const double _eyeHalfW = 0.115;
  static const double _eyeHalfH = 0.085;

  @override
  void paint(Canvas canvas, Size size) {
    if (closeFraction < 0.05) return;
    final paint = Paint()..color = _skinColour;
    for (final centre in _eyeCentres) {
      final cx = size.width * centre.dx;
      final eyeTop = size.height * (centre.dy - _eyeHalfH);
      final lidH = size.height * _eyeHalfH * 2 * closeFraction;
      // Lid descends from the top of the eye downward.
      canvas.drawOval(
        Rect.fromLTRB(
          cx - size.width * _eyeHalfW,
          eyeTop,
          cx + size.width * _eyeHalfW,
          eyeTop + lidH,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BlinkOverlayPainter old) =>
      old.closeFraction != closeFraction;
}

/// Draws animated gold 4-point star overlays over both eyes.
///
/// Stars rotate and pulse at 1 revolution per 1.8 seconds.
class _StarEyesOverlayPainter extends CustomPainter {
  const _StarEyesOverlayPainter({
    required this.rotation,
    required this.pulse,
  });

  final double rotation;
  final double pulse;

  static const List<Offset> _eyeCentres = [
    Offset(0.33, 0.36),
    Offset(0.57, 0.37),
  ];
  static const double _starR = 0.065;

  @override
  void paint(Canvas canvas, Size size) {
    final eraser = Paint()..color = Colors.white;
    final gold = Paint()
      ..color = const Color(0xFFFFB400)
      ..strokeWidth = size.width * 0.013
      ..strokeCap = StrokeCap.round;
    final goldFill = Paint()..color = const Color(0xFFFFB400);

    for (final centre in _eyeCentres) {
      final cx = size.width * centre.dx;
      final cy = size.height * centre.dy;
      final r = size.width * _starR * pulse;

      // Erase iris.
      canvas.drawCircle(Offset(cx, cy), r * 1.05, eraser);

      // 4-point star, rotated.
      for (int i = 0; i < 4; i++) {
        final angle = rotation + math.pi / 4 * i;
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
  bool shouldRepaint(_StarEyesOverlayPainter old) =>
      old.rotation != rotation || old.pulse != pulse;
}
