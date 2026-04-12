import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_svg/flutter_svg.dart';

/// Renders the Postman James SVG character with native SVG shape animations.
///
/// Animations:
/// - Head-bob (sine wave) while [isTalking]
/// - Mouth cycle (path8 → A → O → E) while [isTalking], using SVG native shapes
/// - Periodic blink every 3–6 seconds, using SVG native closed-eye layers
/// - Gold spinning star-eyes when [showStarEyes] (canvas overlay)
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
  Timer? _blinkTimer;

  // Talking frames: 4 SVG strings (path8/A/O/E), eyes open.
  List<String> _talkingFrames = const [];
  // Blink frames: same 4 strings but with eyes closed.
  List<String> _blinkFrames = const [];

  /// Toggles display visibility for the SVG element with [elementId].
  /// Handles elements that already have display:X, or whose style has no
  /// display property yet (e.g. path8 default smile).
  static String _setVisible(String svg, String elementId, bool visible) {
    final want = visible ? 'display:inline' : 'display:none';
    final opposite = visible ? 'display:none' : 'display:inline';
    // [^>] matches newlines in Dart, so multi-line Inkscape opening tags work.
    final tagRe = RegExp(r'<[^>]*\bid="' + elementId + r'"[^>]*>');
    return svg.replaceFirstMapped(tagRe, (match) {
      final tag = match.group(0)!;
      if (tag.contains(opposite)) {
        return tag.replaceFirst(opposite, want);
      } else if (tag.contains(RegExp(r'display:[^;>"]*'))) {
        return tag.replaceFirstMapped(
          RegExp(r'display:[^;>"]*'),
          (_) => want,
        );
      } else if (tag.contains('style="')) {
        return tag.replaceFirst('style="', 'style="$want;');
      }
      return tag; // already correct
    });
  }

  /// Returns an SVG string with [activeMouthId] visible and all other
  /// mouth shapes hidden.
  static String _applyMouth(String svg, String activeMouthId) {
    const allMouths = [
      'path8', 'path12', 'path17', 'path18', 'path23',
      'path24', 'path25', 'path26', 'path27', 'path28', 'path29',
    ];
    var result = svg;
    for (final id in allMouths) {
      result = _setVisible(result, id, id == activeMouthId);
    }
    return result;
  }

  /// Returns an SVG string with open/closed eyes toggled for blinking.
  static String _applyBlink(String svg) {
    var result = svg;
    result = _setVisible(result, 'layer5', false);  // Left Eye open: hide
    result = _setVisible(result, 'layer6', false);  // Right Eye open: hide
    result = _setVisible(result, 'layer9', true);   // Left Eye Closed: show
    result = _setVisible(result, 'layer10', true);  // Right Eye Closed: show
    return result;
  }

  Future<void> _loadSvgVariants() async {
    final base = await rootBundle.loadString('assets/postman_james.svg');
    if (!mounted) return;
    const cycle = ['path8', 'path17', 'path18', 'path23'];
    final talking = cycle.map((id) => _applyMouth(base, id)).toList();
    final blink = talking.map(_applyBlink).toList();
    setState(() {
      _talkingFrames = talking;
      _blinkFrames = blink;
    });
  }

  @override
  void initState() {
    super.initState();

    _bobController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );

    _mouthController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 880),
    );

    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );

    _starController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );

    _loadSvgVariants();

    if (widget.isTalking) _startTalkingAnimations();
    if (widget.showStarEyes) _starController.repeat();
    _scheduleBlink();
  }

  void _startTalkingAnimations() {
    _bobController.repeat();
    _mouthController.repeat();
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
    // Show static asset while SVG variants are loading (first frame only).
    if (_talkingFrames.isEmpty) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: SvgPicture.asset(
          'assets/postman_james.svg',
          width: widget.size,
          height: widget.size,
          fit: BoxFit.contain,
        ),
      );
    }

    return AnimatedBuilder(
      animation:
          Listenable.merge([_bobController, _mouthController, _blinkController]),
      builder: (context, _) {
        final bob = math.sin(_bobController.value * 2 * math.pi) * 2.5;
        final mouthIdx =
            (_mouthController.value * 4).floor().clamp(0, 3);
        final isBlinking = _blinkController.value > 0.05;
        final svgFrame = isBlinking
            ? _blinkFrames[mouthIdx]
            : _talkingFrames[mouthIdx];

        return Transform.translate(
          offset: Offset(0, bob),
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: Stack(
              children: [
                SvgPicture.string(
                  svgFrame,
                  width: widget.size,
                  height: widget.size,
                  fit: BoxFit.contain,
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
