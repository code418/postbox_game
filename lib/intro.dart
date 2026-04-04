import 'dart:math';

import 'package:flutter/material.dart';
import 'package:animated_text_kit/animated_text_kit.dart';
import 'package:postbox_game/theme.dart';

/// First-run cinematic intro: postbox on stage, Postman James, dialogue, then app overview.
/// [replay] true when opened from Settings — on done just pops.
/// [onDone] called when user completes the intro on first run (optional).
class Intro extends StatefulWidget {
  const Intro({
    Key? key,
    this.replay = false,
    this.onDone,
  }) : super(key: key);

  final bool replay;
  final VoidCallback? onDone;

  @override
  State<Intro> createState() => _IntroState();
}

class _IntroState extends State<Intro> with TickerProviderStateMixin {
  int _step = 0;
  static const int _totalSteps = 7;

  late AnimationController _jamesWalkController;
  late AnimationController _starsController;
  late Animation<double> _jamesSlide;

  @override
  void initState() {
    super.initState();
    _jamesWalkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _jamesSlide = Tween<double>(begin: -1.0, end: 0.0).animate(
      CurvedAnimation(parent: _jamesWalkController, curve: Curves.easeOut),
    );
    _starsController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
  }

  @override
  void dispose() {
    _jamesWalkController.dispose();
    _starsController.dispose();
    super.dispose();
  }

  void _advance() {
    if (_step == 1) _jamesWalkController.forward();
    if (_step == 3) _starsController.forward();
    if (_step < _totalSteps - 1) {
      setState(() => _step++);
    } else {
      if (widget.replay) {
        Navigator.of(context).pop();
      } else {
        widget.onDone?.call();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [royalNavy, Color(0xFF3D0C13)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Expanded(child: _buildStep()),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _advance,
                    child:
                        Text(_step == _totalSteps - 1 ? 'Get started' : 'Next'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case 0:
        return _buildStageWithPostbox();
      case 1:
        return _buildJamesWalksIn();
      case 2:
        return _buildDialogue(
          'Hi, my name is Postman James.\nWhat you see here is a normal postbox.',
        );
      case 3:
        return _buildDialogue('Do you know what I see?');
      case 4:
        return _buildMegaPoints();
      case 5:
        return _buildOverview();
      case 6:
        return _buildOverviewEnd();
      default:
        return _buildStageWithPostbox();
    }
  }

  Widget _buildStageWithPostbox() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'The Postbox Game',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: AppSpacing.xxl),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xl, vertical: AppSpacing.lg),
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white24, width: 2),
            ),
            child: const Column(
              children: [
                Icon(Icons.mail, size: 80, color: postalRed),
                SizedBox(height: AppSpacing.sm),
                Text(
                  'A normal postbox',
                  style: TextStyle(color: Colors.white70, fontSize: 18),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildJamesWalksIn() {
    return AnimatedBuilder(
      animation: _jamesSlide,
      builder: (context, child) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 40),
              FractionalTranslation(
                translation: Offset(_jamesSlide.value, 0),
                child: PostManJames(showStarEyes: false, size: 100),
              ),
              const SizedBox(height: AppSpacing.lg),
              const Text(
                'Postman James arrives',
                style: TextStyle(color: Colors.white70, fontSize: 20),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDialogue(String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            PostManJames(showStarEyes: false, size: 90),
            const SizedBox(height: AppSpacing.xl),
            Container(
              padding: const EdgeInsets.all(AppSpacing.lg),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white, fontSize: 22, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMegaPoints() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            PostManJames(showStarEyes: true, size: 90),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Mega points!',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: postalGold,
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOverview() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg + 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'How it works',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: AppSpacing.lg),
            _overviewRow(Icons.location_searching, 'Find postboxes near you'),
            _overviewRow(Icons.add_location,
                'Claim them when you\'re there to score points'),
            _overviewRow(Icons.leaderboard,
                'Climb the leaderboard and compete with friends'),
          ],
        ),
      ),
    );
  }

  Widget _overviewRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: postalGold, size: 28),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                  color: Colors.white, fontSize: 18, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverviewEnd() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.thumb_up, size: 64, color: postalGold),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Sign in or create an account to start collecting mega points.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white.withValues(alpha:0.9),
                  fontSize: 20,
                  height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

/// Postman James character drawn with CustomPainter.
/// [showStarEyes] true for the "Mega points!" moment.
class PostManJames extends StatelessWidget {
  const PostManJames(
      {Key? key, this.showStarEyes = false, this.size = 120})
      : super(key: key);

  final bool showStarEyes;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: size,
      width: size,
      child: CustomPaint(
        painter: _JamesPainter(showStarEyes: showStarEyes),
      ),
    );
  }
}

class _JamesPainter extends CustomPainter {
  final bool showStarEyes;

  _JamesPainter({required this.showStarEyes});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Body — navy rectangle
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.25, h * 0.48, w * 0.5, h * 0.42),
        Radius.circular(w * 0.08),
      ),
      Paint()..color = royalNavy,
    );

    // Post bag — red rectangle on left hip
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.12, h * 0.58, w * 0.16, h * 0.2),
        Radius.circular(w * 0.04),
      ),
      Paint()..color = postalRed,
    );

    // Cap brim — red rectangle
    canvas.drawRect(
      Rect.fromLTWH(w * 0.18, h * 0.17, w * 0.64, h * 0.07),
      Paint()..color = postalRed,
    );

    // Cap top — red rounded top
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.22, h * 0.04, w * 0.56, h * 0.16),
        Radius.circular(w * 0.1),
      ),
      Paint()..color = postalRed,
    );

    // Face — skin-tone circle
    canvas.drawCircle(
      Offset(w * 0.5, h * 0.38),
      w * 0.18,
      Paint()..color = const Color(0xFFFFDDB4),
    );

    // Eyes
    if (showStarEyes) {
      // Star eyes (amber sparkle dots)
      _drawStar(canvas, Offset(w * 0.42, h * 0.37), w * 0.045, postalGold);
      _drawStar(canvas, Offset(w * 0.58, h * 0.37), w * 0.045, postalGold);
    } else {
      // Normal dot eyes
      canvas.drawCircle(
        Offset(w * 0.43, h * 0.37),
        w * 0.028,
        Paint()..color = const Color(0xFF333333),
      );
      canvas.drawCircle(
        Offset(w * 0.57, h * 0.37),
        w * 0.028,
        Paint()..color = const Color(0xFF333333),
      );
    }

    // Smile
    final smilePath = Path()
      ..moveTo(w * 0.42, h * 0.44)
      ..quadraticBezierTo(w * 0.5, h * 0.49, w * 0.58, h * 0.44);
    canvas.drawPath(
      smilePath,
      Paint()
        ..color = const Color(0xFF8B4513)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.02
        ..strokeCap = StrokeCap.round,
    );
  }

  void _drawStar(Canvas canvas, Offset center, double r, Color color) {
    final paint = Paint()..color = color;
    for (var i = 0; i < 4; i++) {
      final angle = i * pi / 4;
      canvas.drawLine(
        Offset(center.dx + cos(angle) * r * 1.5,
            center.dy + sin(angle) * r * 1.5),
        Offset(center.dx - cos(angle) * r * 1.5,
            center.dy - sin(angle) * r * 1.5),
        paint
          ..strokeWidth = r * 0.5
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.drawCircle(center, r * 0.5, paint..strokeWidth = 0);
  }

  @override
  bool shouldRepaint(covariant _JamesPainter old) =>
      old.showStarEyes != showStarEyes;
}

/// Legacy ChatWindow using AnimatedTextKit (kept for reference).
class ChatWindow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 250.0,
      child: AnimatedTextKit(
        animatedTexts: [
          TypewriterAnimatedText(
            'Hi, I\'m Postman James!',
            textStyle: const TextStyle(fontSize: 24.0, color: Colors.white),
          ),
        ],
        onTap: () {},
      ),
    );
  }
}
