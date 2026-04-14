import 'package:animated_text_kit/animated_text_kit.dart';
import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_svg/flutter_svg.dart';
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
  late final ConfettiController _confettiController;

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
    _confettiController =
        ConfettiController(duration: const Duration(seconds: 6));
  }

  @override
  void dispose() {
    _jamesWalkController.dispose();
    _confettiController.dispose();
    super.dispose();
  }

  void _advance() {
    if (_step == 0) _jamesWalkController.forward();
    // Fire confetti when the user taps into the Mega Points step.
    if (_step == 3) _confettiController.play();
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
          )
              .animate()
              .fadeIn(duration: 600.ms)
              .slideY(begin: 0.3, duration: 600.ms, curve: Curves.easeOut),
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
                SvgPicture.asset('assets/postbox.svg', width: 120, height: 120)
                    .animate(delay: 200.ms)
                    .fadeIn(duration: 600.ms)
                    .scale(
                      begin: const Offset(0.6, 0.6),
                      duration: 600.ms,
                      curve: Curves.elasticOut,
                    ),
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
                  SvgPicture.asset('assets/postbox.svg', width: 80, height: 80)
                      .animate()
                      .fadeIn(duration: 500.ms),
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
              ).animate(delay: 1000.ms).fadeIn(duration: 400.ms),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDialogue(String text) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
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
            ).animate().fadeIn(duration: 400.ms),
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
            )
                .animate(delay: 200.ms)
                .fadeIn(duration: 500.ms)
                .slideY(begin: 0.2, duration: 400.ms, curve: Curves.easeOut),
          ],
          ),
        ),
      ),
    );
  }

  Widget _buildMegaPoints() {
    return Stack(
      alignment: Alignment.topCenter,
      children: [
        // Confetti fires from the top-centre when this step is entered.
        Align(
          alignment: Alignment.topCenter,
          child: ConfettiWidget(
            confettiController: _confettiController,
            blastDirectionality: BlastDirectionality.explosive,
            colors: const [postalGold, postalRed, Colors.white],
            numberOfParticles: 30,
            gravity: 0.2,
          ),
        ),
        Center(
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
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        color: postalGold,
                        fontWeight: FontWeight.bold,
                      ),
                )
                    .animate(onPlay: (c) => c.repeat(reverse: true))
                    .shimmer(duration: 1200.ms, color: Colors.white70)
                    .scale(
                      begin: const Offset(0.95, 0.95),
                      end: const Offset(1.05, 1.05),
                      duration: 800.ms,
                    ),
              ],
            ),
          ),
        ),
      ],
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
            ).animate().fadeIn(duration: 400.ms),
            const SizedBox(height: AppSpacing.lg),
            _overviewRow(Icons.location_searching, 'Find postboxes near you', 0),
            _overviewRow(Icons.add_location,
                'Claim them when you\'re there to score points', 1),
            _overviewRow(Icons.leaderboard,
                'Climb the leaderboard and compete with friends', 2),
          ],
        ),
      ),
    );
  }

  Widget _overviewRow(IconData icon, String text, int index) {
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
    )
        .animate(delay: (index * 150).ms)
        .fadeIn(duration: 400.ms)
        .slideX(begin: -0.2, duration: 400.ms, curve: Curves.easeOut);
  }

  Widget _buildOverviewEnd() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.thumb_up, size: 64, color: postalGold)
                .animate()
                .scale(
                  begin: const Offset(0.3, 0.3),
                  duration: 600.ms,
                  curve: Curves.elasticOut,
                ),
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
            ).animate(delay: 300.ms).fadeIn(duration: 500.ms),
          ],
        ),
      ),
    );
  }
}
