import 'dart:async';

import 'package:animated_text_kit/animated_text_kit.dart';
import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/consent_preferences.dart';
import 'package:postbox_game/consent_screen.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/postman_james.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/services/perf_service.dart';
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

class _IntroState extends State<Intro> {
  int _step = 0;
  static const int _totalSteps = 8;

  /// Analytics choice made on the final (disclosure) step. Default ON —
  /// opt-out model; the switch lets the user turn it off before starting.
  bool _analyticsOptIn = true;

  /// Settings replay skips the consent step (consent is managed from
  /// Settings → Privacy once the choice exists), so the replay run terminates
  /// one step earlier.
  int get _lastStep => widget.replay ? _totalSteps - 2 : _totalSteps - 1;

  /// True once [_advance] has fired the terminal-step branch (pop / onDone)
  /// so a double-tap on "Get started" can't pop the screen twice or invoke
  /// [Intro.onDone] more than once. Without this guard, a rapid second tap
  /// before the navigator transition completes would re-enter the else
  /// branch with `_step` unchanged and either pop the screen below Intro
  /// (replay mode) or mark intro-seen twice.
  bool _completed = false;

  late final ConfettiController _confettiController;

  // First-run onboarding trace (skipped on Settings replay). Started in
  // initState, stopped when the user reaches the terminal "Get started" step.
  // `variant` records which welcome-copy A/B variant they saw.
  Future<TraceHandle>? _onboardingTrace;

  @override
  void initState() {
    super.initState();
    _confettiController =
        ConfettiController(duration: const Duration(seconds: 4));
    if (!widget.replay) {
      _onboardingTrace = PerfService.start(
        PerfTraces.introOnboarding,
        attributes: {
          PerfTraces.attrVariant: RemoteConfigService.instance.jamesWelcomeVariant,
        },
      );
    }
  }

  @override
  void dispose() {
    _confettiController.dispose();
    super.dispose();
  }

  void _advance() {
    if (_completed) return;
    // Fire confetti as the user enters the Mega Points step.
    if (_step == 3) _confettiController.play();
    if (_step < _lastStep) {
      setState(() => _step++);
    } else {
      _completed = true;
      final trace = _onboardingTrace;
      if (trace != null) {
        unawaited(trace.then((h) => h.stop()));
      }
      if (widget.replay) {
        Navigator.of(context).pop();
      } else {
        // Persist the consent-step choice and apply it immediately so
        // analytics starts (or stays off) without waiting for a restart.
        unawaited(ConsentPreferences.setAnalyticsConsent(_analyticsOptIn));
        unawaited(Analytics.setCollectionEnabled(_analyticsOptIn));
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
                    child: Text(_step == _lastStep ? 'Get started' : 'Next'),
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
      case 7:
        return _buildConsent();
      default:
        return _buildStageWithPostbox();
    }
  }

  /// Final first-run step: GDPR telemetry disclosure + analytics opt-in.
  /// Never reached on replay (see [_lastStep]).
  Widget _buildConsent() {
    return _scrollCentre(
      ConsentContent(
        analyticsOptIn: _analyticsOptIn,
        onAnalyticsChanged: (v) => setState(() => _analyticsOptIn = v),
      ),
    );
  }

  // Wraps a step's content so it scrolls (and stays centred when there's room)
  // instead of overflowing the Expanded slot. Matters in landscape, where the
  // step area is only a few hundred logical pixels tall.
  Widget _scrollCentre(Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl, vertical: AppSpacing.lg),
        child: ConstrainedBox(
          constraints: BoxConstraints(
              minHeight: constraints.maxHeight - 2 * AppSpacing.lg),
          child: Center(child: child),
        ),
      ),
    );
  }

  Widget _buildStageWithPostbox() {
    return _scrollCentre(
      Column(
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
              .fadeIn(duration: 500.ms)
              .slideY(begin: -0.2, end: 0, duration: 500.ms, curve: Curves.easeOut),
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
                SvgPicture.asset(
                  'assets/postbox.svg',
                  width: 120,
                  height: 120,
                  // Decorative — dialogue text below carries the content.
                  excludeFromSemantics: true,
                )
                    .animate()
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
                ).animate(delay: 300.ms).fadeIn(duration: 400.ms),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildJamesWalksIn() {
    return _scrollCentre(
      Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 40),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SvgPicture.asset(
                'assets/postbox.svg',
                width: 80,
                height: 80,
                excludeFromSemantics: true,
              ),
              const SizedBox(width: AppSpacing.lg),
              const PostmanJames(size: 100)
                  .animate()
                  .slideX(
                    begin: -1.5,
                    end: 0,
                    duration: 900.ms,
                    curve: Curves.easeOutBack,
                  )
                  .fadeIn(duration: 400.ms),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          const Text(
            'Look, it\'s a Postie!',
            style: TextStyle(color: Colors.white70, fontSize: 20),
          ).animate(delay: 900.ms).fadeIn(duration: 400.ms),
        ],
      ),
    );
  }

  Widget _buildDialogue(String text) {
    return LayoutBuilder(
      key: ValueKey(text),
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
                SvgPicture.asset(
                  'assets/postbox.svg',
                  width: 64,
                  height: 64,
                  excludeFromSemantics: true,
                ),
                const SizedBox(width: AppSpacing.md),
                const PostmanJames(size: 90, isTalking: true),
              ],
            )
                .animate()
                .fadeIn(duration: 400.ms)
                .slideY(begin: -0.15, end: 0, duration: 400.ms, curve: Curves.easeOut),
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
                .fadeIn(duration: 400.ms)
                .slideY(begin: 0.2, end: 0, duration: 400.ms, curve: Curves.easeOut),
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
        _scrollCentre(
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const PostmanJames(size: 160, showStarEyes: true, isTalking: true),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Points, baby! Sweet, beautiful, points!',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: postalGold,
                      fontWeight: FontWeight.bold,
                    ),
              )
                  .animate(onPlay: (c) => c.repeat())
                  .shimmer(
                    duration: 1200.ms,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
            ],
          ),
        ),
        // Confetti is drawn on top, anchored to the top so particles spray
        // outwards as the user lands on this step.
        Align(
          alignment: Alignment.topCenter,
          child: ConfettiWidget(
            confettiController: _confettiController,
            blastDirectionality: BlastDirectionality.explosive,
            colors: const [postalGold, postalRed, Colors.white],
            numberOfParticles: 24,
            gravity: 0.25,
            emissionFrequency: 0.04,
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
          children: <Widget>[
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
          ]
              .animate(interval: 120.ms)
              .fadeIn(duration: 400.ms)
              .slideX(begin: 0.15, end: 0, duration: 400.ms, curve: Curves.easeOut),
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
    return _scrollCentre(
      Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.thumb_up, size: 64, color: postalGold)
              .animate()
              .scale(
                begin: const Offset(0.5, 0.5),
                duration: 500.ms,
                curve: Curves.elasticOut,
              )
              .fadeIn(duration: 300.ms),
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
          )
              .animate(delay: 300.ms)
              .fadeIn(duration: 400.ms)
              .slideY(begin: 0.2, end: 0, duration: 400.ms, curve: Curves.easeOut),
        ],
      ),
    );
  }
}
