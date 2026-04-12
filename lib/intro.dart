import 'package:animated_text_kit/animated_text_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'dart:math' as math;

import 'package:particles_flutter/engine.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/postman_james_svg.dart';
import 'package:postbox_game/theme.dart';

/// First-run cinematic intro: postbox on stage, Postman James, dialogue, then app overview.
/// [replay] true when opened from Settings — on done just pops.
/// [onDone] called when user completes the intro on first run (optional).
class Intro extends StatefulWidget {
  const Intro({
    super.key,
    this.replay = false,
    this.onDone,
  });

  final bool replay;
  final VoidCallback? onDone;

  @override
  State<Intro> createState() => _IntroState();
}

class _IntroState extends State<Intro> with TickerProviderStateMixin {
  int _step = 0;
  static const int _totalSteps = 7;

  late AnimationController _jamesWalkController;
  late Animation<double> _jamesSlide;
  late final List<Particle> _particles;

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
    _particles = _buildParticles();
  }

  static List<Particle> _buildParticles() {
    final rng = math.Random();
    return List.generate(25, (_) {
      final speed = 0.3 + rng.nextDouble() * 0.7;
      final angle = rng.nextDouble() * 2 * math.pi;
      return CircularParticle(
        radius: 1.0 + rng.nextDouble() * 3.0,
        color: Colors.white.withValues(alpha: 0.1 + rng.nextDouble() * 0.12),
        velocity: Offset(
          math.cos(angle) * speed * 30,
          math.sin(angle) * speed * 30,
        ),
      );
    });
  }

  @override
  void dispose() {
    _jamesWalkController.dispose();
    super.dispose();
  }

  void _advance() {
    // Start the walk animation when entering step 1 (James slides in from left).
    if (_step == 0) _jamesWalkController.forward();
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
        child: Stack(
          children: [
            // Subtle floating particles behind all intro content.
            Positioned.fill(
              child: Particles(
                particles: _particles,
                height: MediaQuery.of(context).size.height,
                width: MediaQuery.of(context).size.width,
                boundType: BoundType.WrapAround,
                connectDots: false,
              ),
            ),
            SafeArea(
              child: Column(
                children: [
                  Expanded(child: _buildStep()),
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _advance,
                        child: Text(
                            _step == _totalSteps - 1 ? 'Get started' : 'Next'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
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
        return _buildDialogue(JamesMessages.introStep2.resolve());
      case 3:
        return _buildDialogue(JamesMessages.introStep3.resolve());
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
            child: Column(
              children: [
                SvgPicture.asset('assets/postbox.svg', width: 120, height: 120),
                const SizedBox(height: AppSpacing.sm),
                const Text(
                  'A brief introduction to postboxes...',
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
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  SvgPicture.asset('assets/postbox.svg', width: 80, height: 80),
                  const SizedBox(width: AppSpacing.lg),
                  FractionalTranslation(
                    translation: Offset(_jamesSlide.value, 0),
                    child: const PostmanJamesSvg(size: 100),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              const Text(
                'Look, it\'s a Postie!',
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
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SvgPicture.asset('assets/postbox.svg', width: 64, height: 64),
                const SizedBox(width: AppSpacing.md),
                const PostmanJamesSvg(size: 90, isTalking: true),
              ],
            ),
            const SizedBox(height: AppSpacing.xl),
            Container(
              padding: const EdgeInsets.all(AppSpacing.lg),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(12),
              ),
              child: AnimatedTextKit(
                key: ValueKey(text),
                animatedTexts: [
                  TypewriterAnimatedText(
                    text,
                    textAlign: TextAlign.center,
                    textStyle: const TextStyle(
                        color: Colors.white, fontSize: 22, height: 1.4),
                    speed: const Duration(milliseconds: 35),
                  ),
                ],
                totalRepeatCount: 1,
                displayFullTextOnTap: true,
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
            const PostmanJamesSvg(
                size: 160, showStarEyes: true, isTalking: true),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Points, baby! Sweet, beautiful, points!',
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
              widget.replay
                  ? 'Get out there and find some mega-rare postboxes!'
                  : 'Sign in or create an account to start collecting mega points.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontSize: 20,
                  height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
