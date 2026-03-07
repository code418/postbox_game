import 'package:flutter/material.dart';
import 'package:animated_text_kit/animated_text_kit.dart';

/// First-run cinematic intro: postbox on stage, Postman James, dialogue, then app overview.
/// [replay] true when opened from Settings — on done just pops. When false, [onDone] is called (e.g. show login).
class Intro extends StatefulWidget {
  const Intro({
    Key? key,
    this.replay = false,
    required this.onDone,
  }) : super(key: key);

  final bool replay;
  final VoidCallback onDone;

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
        widget.onDone();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.indigo.shade900,
              Colors.purple.shade900,
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: _buildStep(),
              ),
              Padding(
                padding: const EdgeInsets.all(24.0),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _advance,
                    child: Text(_step == _totalSteps - 1 ? 'Get started' : 'Next'),
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
          const SizedBox(height: 48),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white24, width: 2),
            ),
            child: Column(
              children: [
                Icon(Icons.mail, size: 80, color: Colors.red.shade700),
                const SizedBox(height: 8),
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
              const SizedBox(height: 24),
              Text(
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
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            PostManJames(showStarEyes: false, size: 90),
            const SizedBox(height: 32),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 22, height: 1.4),
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
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            PostManJames(showStarEyes: true, size: 90),
            const SizedBox(height: 24),
            Text(
              'Mega points!',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.amber,
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
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'How it works',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 24),
            _overviewRow(Icons.location_searching, 'Find postboxes near you'),
            _overviewRow(Icons.add_location, 'Claim them when you\'re there to score points'),
            _overviewRow(Icons.leaderboard, 'Climb the leaderboard and compete with friends'),
          ],
        ),
      ),
    );
  }

  Widget _overviewRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.amber, size: 28),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white, fontSize: 18, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverviewEnd() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.thumb_up, size: 64, color: Colors.amber.shade300),
            const SizedBox(height: 24),
            Text(
              'Sign in or create an account to start collecting mega points.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 20, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

/// Placeholder for Postman James (was Flare asset james.flr; flare_flutter is incompatible with Dart 3).
/// [showStarEyes] true for the "Mega points!" moment.
class PostManJames extends StatelessWidget {
  const PostManJames({Key? key, this.showStarEyes = false, this.size = 120}) : super(key: key);

  final bool showStarEyes;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: size,
      width: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(Icons.person, size: size, color: Theme.of(context).colorScheme.primary),
          if (showStarEyes)
            Positioned(
              top: size * 0.2,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_awesome, color: Colors.amber, size: size * 0.2),
                  SizedBox(width: size * 0.15),
                  Icon(Icons.auto_awesome, color: Colors.amber, size: size * 0.2),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Legacy ChatWindow using AnimatedTextKit (kept for reference; intro uses step-based dialogue).
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
