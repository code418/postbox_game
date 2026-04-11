import 'dart:async';
import 'dart:math' show pi;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:geolocator/geolocator.dart';
import 'package:postbox_game/app_preferences.dart';
import 'package:postbox_game/james_controller.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/streak_service.dart';
import 'package:postbox_game/theme.dart';

enum ClaimStage { initial, searching, results, empty, quiz, quizFailed, claimed }

class Claim extends StatefulWidget {
  const Claim({super.key});

  @override
  ClaimState createState() => ClaimState();
}

class ClaimState extends State<Claim> with SingleTickerProviderStateMixin {
  int _count = 0;
  int _maxPoints = 0;
  int _minPoints = 0;
  int _claimedToday = 0;
  Map<String, dynamic> _postboxes = {};
  String? _quizCipher;
  String? _selectedAnswer;
  List<String> _quizOptions = [];
  DistanceUnit _distanceUnit = DistanceUnit.meters;
  int _pointsEarned = 0;
  int _claimedCount = 0;
  bool _isClaiming = false;

  ClaimStage currentStage = ClaimStage.initial;

  late AnimationController _successController;
  late Animation<double> _successScale;
  late ConfettiController _confettiController;
  // Cached so StreamBuilder doesn't re-subscribe on every rebuild.
  late final Stream<int?> _streakStream = _streakService.streakStream();

  @override
  void initState() {
    super.initState();
    _successController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _successScale = CurvedAnimation(
      parent: _successController,
      curve: Curves.elasticOut,
    );
    _confettiController = ConfettiController(duration: const Duration(seconds: 3));
    AppPreferences.getDistanceUnit().then((unit) {
      if (mounted) setState(() => _distanceUnit = unit);
    });
  }

  @override
  void dispose() {
    _successController.dispose();
    _confettiController.dispose();
    super.dispose();
  }

  final HttpsCallable _callable =
      FirebaseFunctions.instance.httpsCallable('nearbyPostboxes');
  final HttpsCallable _claimCallable =
      FirebaseFunctions.instance.httpsCallable('startScoring');
  final StreakService _streakService = StreakService();

  Future<Position> _getPosition() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('Location services are disabled.');
    }
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw Exception('Location permission denied.');
      }
    }
    if (permission == LocationPermission.deniedForever) {
      throw Exception('Location permission permanently denied. Enable in Settings.');
    }
    return Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
  }

  Future<void> _startSearch() async {
    // Set searching state synchronously before any awaits so rapid
    // double-taps cannot fire two concurrent Firebase requests.
    setState(() => currentStage = ClaimStage.searching);
    _distanceUnit = await AppPreferences.getDistanceUnit();
    try {
      final position = await _getPosition();
      final result = await _callable.call(<String, dynamic>{
        'lat': position.latitude,
        'lng': position.longitude,
        'meters': AppPreferences.claimRadiusMeters,
      });
      setState(() {
        _count = result.data['counts']['total'] ?? 0;
        _maxPoints = result.data['points']['max'] ?? 0;
        _minPoints = result.data['points']['min'] ?? 0;
        _claimedToday = result.data['counts']['claimedToday'] ?? 0;
        _postboxes = Map<String, dynamic>.from(result.data['postboxes'] ?? {});
        currentStage = _count > 0 ? ClaimStage.results : ClaimStage.empty;
      });
    } on FirebaseFunctionsException catch (e) {
      debugPrint('Firebase functions error: ${e.code} ${e.message}');
      final isOffline = e.code == 'unavailable';
      _showErrorSnackBar(isOffline
          ? 'No internet connection. Please try again.'
          : 'Could not scan for postboxes. Please try again.');
      if (mounted) {
        JamesController.of(context).show(JamesMessages.claimErrorGeneral.resolve());
      }
      setState(() => currentStage = ClaimStage.initial);
    } catch (e) {
      debugPrint('Error scanning: $e');
      _showErrorSnackBar(e.toString().replaceFirst('Exception: ', ''));
      setState(() => currentStage = ClaimStage.initial);
    }
  }

  Future<void> _claimPostbox() async {
    setState(() => _isClaiming = true);
    HapticFeedback.mediumImpact();
    try {
      final position = await _getPosition();
      final result = await _claimCallable.call(<String, dynamic>{
        'lat': position.latitude,
        'lng': position.longitude,
      });
      final found = result.data?['found'] == true;
      final allClaimedToday = result.data?['allClaimedToday'] == true;
      final rawClaimed = result.data?['claimed'] ?? 0;
      final claimedCount = rawClaimed is int ? rawClaimed : (rawClaimed as num).toInt();

      if (!found) {
        // User moved out of range between scan and claim.
        setState(() => _isClaiming = false);
        if (mounted) {
          JamesController.of(context).show(JamesMessages.claimOutOfRange.resolve());
        }
        await _startSearch();
        return;
      }
      if (allClaimedToday || claimedCount == 0) {
        setState(() => _isClaiming = false);
        _showErrorSnackBar('Already claimed today — come back tomorrow!');
        if (mounted) {
          JamesController.of(context).show(JamesMessages.claimErrorAlreadyClaimed.resolve());
        }
        await _startSearch();
        return;
      }
      final points = result.data?['points'] ?? 0;
      setState(() {
        _pointsEarned = points is int ? points : (points as num).toInt();
        _claimedCount = claimedCount;
        _isClaiming = false;
        currentStage = ClaimStage.claimed;
      });
      _successController.forward(from: 0);
      _confettiController.play();
      try {
        final claimDate = result.data?['dailyDate'] as String?;
        await _streakService.updateStreakAfterClaim(claimDate: claimDate);
      } catch (e) {
        debugPrint('Streak update failed (non-fatal): $e');
      }
      if (mounted) {
        final String msg;
        if (_claimedCount > 1) {
          msg = JamesMessages.claimSuccessMulti(_claimedCount, _pointsEarned);
        } else {
          // Fire the rare message when the per-box score indicates a rare cipher
          // (VR=7, EVIIR/CIIIR=9, EVIIIR=12 all score ≥ 7).
          final avgPts = _claimedCount > 0 ? _pointsEarned / _claimedCount : 0;
          msg = avgPts >= 7
              ? JamesMessages.claimSuccessRare.resolve()
              : JamesMessages.claimSuccessStandard.resolve();
        }
        JamesController.of(context).show(msg);
      }
    } on FirebaseFunctionsException catch (e) {
      debugPrint('Claim error: ${e.code} ${e.message}');
      final snackMsg = e.code == 'unavailable'
          ? 'No internet connection. Please try again.'
          : (e.message ?? 'Could not claim postbox.');
      _showErrorSnackBar(snackMsg);
      setState(() => _isClaiming = false);
      if (mounted) {
        final msg = (e.code == 'already-claimed')
            ? JamesMessages.claimErrorAlreadyClaimed.resolve()
            : (e.code == 'out-of-range')
                ? JamesMessages.claimErrorOutOfRange.resolve()
                : JamesMessages.claimErrorGeneral.resolve();
        JamesController.of(context).show(msg);
      }
    } catch (e) {
      debugPrint('Claim error: $e');
      final msg = e.toString().contains('permission')
          ? JamesMessages.nearbyErrorPermission.resolve()
          : JamesMessages.claimErrorGeneral.resolve();
      _showErrorSnackBar('Could not claim postbox. Please try again.');
      setState(() => _isClaiming = false);
      if (mounted) JamesController.of(context).show(msg);
    }
  }

  String? _pickQuizCipher() {
    // Collect all ciphers from unclaimed postboxes and pick randomly so the
    // quiz varies when multiple postboxes with different ciphers are nearby.
    final ciphers = <String>[];
    for (final p in _postboxes.values) {
      final map = p as Map<dynamic, dynamic>;
      if (map['claimedToday'] == true) continue;
      final monarch = map['monarch'];
      // Only include ciphers in MonarchInfo.all so the quiz can always build
      // a valid answer pool. An unknown OSM cipher would appear as the
      // "correct" answer but never be in the options list, making the quiz
      // unpassable. Postboxes with unknown ciphers are still claimed directly.
      if (monarch != null &&
          monarch is String &&
          monarch.isNotEmpty &&
          MonarchInfo.all.contains(monarch)) {
        ciphers.add(monarch);
      }
    }
    if (ciphers.isEmpty) return null;
    ciphers.shuffle();
    return ciphers.first;
  }

  List<String> _buildQuizOptions(String correct) {
    final pool = List<String>.from(MonarchInfo.all)..remove(correct)..shuffle();
    return ([correct, ...pool.take(3)]..shuffle());
  }

  void _startQuiz() {
    final cipher = _pickQuizCipher();
    if (cipher == null) {
      _claimPostbox();
      return;
    }
    setState(() {
      _quizCipher = cipher;
      _quizOptions = _buildQuizOptions(cipher);
      _selectedAnswer = null;
      currentStage = ClaimStage.quiz;
    });
  }

  void _onQuizAnswer(String answer) {
    setState(() => _selectedAnswer = answer);
    if (answer == _quizCipher) {
      HapticFeedback.lightImpact();
      _claimPostbox();
    } else {
      HapticFeedback.heavyImpact();
      setState(() => currentStage = ClaimStage.quizFailed);
    }
  }

  Widget _buildAllClaimedBanner(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_clock, color: Colors.orange.shade700),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Already claimed today',
                  style: TextStyle(
                      color: Colors.orange.shade800,
                      fontWeight: FontWeight.w600),
                ),
                Text(
                  'Resets at midnight · London time',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.orange.shade600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red.shade700,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _buildBody(context);
  }

  Widget _buildBody(BuildContext context) {
    switch (currentStage) {
      case ClaimStage.initial:
        return _buildInitial(context);
      case ClaimStage.searching:
        return _buildSearching(context);
      case ClaimStage.results:
        return _buildResults(context);
      case ClaimStage.empty:
        return _buildEmpty(context);
      case ClaimStage.quiz:
        return _buildQuiz(context);
      case ClaimStage.quizFailed:
        return _buildQuizFailed(context);
      case ClaimStage.claimed:
        return _buildClaimed(context);
    }
  }

  Widget _buildInitial(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SvgPicture.asset(
              'assets/postbox.svg',
              height: 100,
              colorFilter: const ColorFilter.mode(postalRed, BlendMode.srcIn),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Find a postbox to claim',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Stand within ${AppPreferences.formatShortDistance(AppPreferences.claimRadiusMeters, _distanceUnit)} of a postbox, then tap below to check if you can claim it.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.grey.shade600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
            // Streak badge — only shown when the user has an active streak.
            StreamBuilder<int?>(
              stream: _streakStream,
              builder: (context, snapshot) {
                final streak = snapshot.data ?? 0;
                if (streak <= 0) return const SizedBox.shrink();
                return Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md, vertical: AppSpacing.xs),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.orange.shade200),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('🔥', style: TextStyle(fontSize: 16)),
                      const SizedBox(width: 6),
                      Text(
                        '$streak-day streak',
                        style: TextStyle(
                          color: Colors.orange.shade800,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton.icon(
              onPressed: _startSearch,
              icon: const Icon(Icons.radar),
              label: const Text('Scan for postboxes nearby'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearching(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: postalRed),
          const SizedBox(height: AppSpacing.md),
          Text('Scanning within ${AppPreferences.formatShortDistance(AppPreferences.claimRadiusMeters, _distanceUnit)}...'),
        ],
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.location_off, size: 80, color: Colors.grey.shade400),
            const SizedBox(height: AppSpacing.md),
            Text(
              'No postboxes found within ${AppPreferences.formatShortDistance(AppPreferences.claimRadiusMeters, _distanceUnit)}',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Try moving closer to a postbox. They have exact locations.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.grey.shade600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton.icon(
              onPressed: _startSearch,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              onPressed: () => setState(() => currentStage = ClaimStage.initial),
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.only(
            top: AppSpacing.md,
            bottom: 100,
          ),
          children: [
            _summaryCard(context),
            const SizedBox(height: AppSpacing.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: OutlinedButton.icon(
                // Disable rescan while a claim is in flight: the in-flight
                // _claimPostbox call still holds setState callbacks that would
                // overwrite whatever state _startSearch transitions to.
                onPressed: _isClaiming ? null : _startSearch,
                icon: const Icon(Icons.refresh),
                label: const Text('Rescan location'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                ),
              ),
            ),
          ],
        ),
        Positioned(
          left: AppSpacing.md,
          right: AppSpacing.md,
          bottom: AppSpacing.md,
          child: _claimedToday == _count
              ? _buildAllClaimedBanner(context)
              : AbsorbPointer(
                  absorbing: _isClaiming,
                  child: FilledButton.icon(
                    onPressed: _isClaiming ? null : _startQuiz,
                    icon: _isClaiming
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.check_circle_outline),
                    label: Text(_isClaiming ? 'Claiming...' : 'Claim this postbox!'),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _summaryCard(BuildContext context) {
    final pointsText = _maxPoints == _minPoints
        ? '$_maxPoints pts'
        : '$_minPoints–$_maxPoints pts';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: postalRed.withValues(alpha:0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.location_on, color: postalRed),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _claimedToday == _count
                        ? (_count == 1
                            ? 'This postbox was claimed today'
                            : 'All $_count postboxes claimed today')
                        : _claimedToday > 0
                            ? '${_count - _claimedToday} of $_count available · $_claimedToday claimed today'
                            : '$_count postbox${_count == 1 ? '' : 'es'} within ${AppPreferences.formatShortDistance(AppPreferences.claimRadiusMeters, _distanceUnit)}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  if (_claimedToday < _count)
                    Text(
                      'Worth $pointsText',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Colors.grey.shade600),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuiz(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.help_outline, size: 64, color: postalRed),
          const SizedBox(height: AppSpacing.md),
          Text(
            'What\'s the cipher on this postbox?',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Look at the postbox and pick the correct royal cipher.',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: Colors.grey.shade600),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xl),
          ..._quizOptions.map((code) {
                final isSelected = _selectedAnswer == code;
                final isCorrectSelected = isSelected && _isClaiming;
                return Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    decoration: BoxDecoration(
                      color: isCorrectSelected
                          ? const Color(0xFF2E7D32).withValues(alpha: 0.08)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: OutlinedButton(
                      onPressed: _isClaiming ? null : () => _onQuizAnswer(code),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 56),
                        side: BorderSide(
                          color: isCorrectSelected
                              ? const Color(0xFF2E7D32)
                              : postalRed,
                          width: isCorrectSelected ? 2 : 1,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (isCorrectSelected) ...[
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFF2E7D32),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                          ],
                          Column(
                            children: [
                              Text(
                                isCorrectSelected ? 'Correct! Claiming…' : code,
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  color: isCorrectSelected
                                      ? const Color(0xFF2E7D32)
                                      : null,
                                ),
                              ),
                              if (!isCorrectSelected)
                                Text(
                                  MonarchInfo.labels[code] ?? code,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: Colors.grey.shade600),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
          const SizedBox(height: AppSpacing.md),
          TextButton(
            onPressed: _isClaiming
                ? null
                : () => setState(() => currentStage = ClaimStage.results),
            child: const Text('Back'),
          ),
        ],
      ),
    );
  }

  Widget _buildQuizFailed(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cancel_outlined, size: 80, color: Colors.red.shade400),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Not quite!',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Take another look at the cipher on the postbox and try again.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.grey.shade600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xl),
            // Return to results (no rescan needed — the postbox hasn't moved).
            FilledButton.icon(
              onPressed: () => setState(() => currentStage = ClaimStage.results),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Try again'),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              onPressed: _startSearch,
              child: const Text('Rescan location'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClaimed(BuildContext context) {
    return Stack(
      children: [
        Align(
          alignment: Alignment.topCenter,
          child: ConfettiWidget(
            confettiController: _confettiController,
            blastDirection: pi / 2,
            blastDirectionality: BlastDirectionality.explosive,
            particleDrag: 0.05,
            emissionFrequency: 0.07,
            numberOfParticles: 20,
            maxBlastForce: 20,
            minBlastForce: 8,
            gravity: 0.3,
            colors: const [postalRed, postalGold, Colors.white, royalNavy],
          ),
        ),
        Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ScaleTransition(
              scale: _successScale,
              child: const Icon(
                Icons.check_circle,
                size: 100,
                color: Color(0xFF2E7D32),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              _claimedCount > 1
                  ? '$_claimedCount postboxes claimed!'
                  : 'Postbox claimed!',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: AppSpacing.sm),
            if (_pointsEarned > 0)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: postalGold.withValues(alpha:0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '+$_pointsEarned points',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: postalGold,
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ),
            StreamBuilder<int?>(
              stream: _streakStream,
              builder: (context, snap) {
                final streak = snap.data ?? 0;
                if (streak < 2) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: Text(
                    '🔥 $streak-day streak!',
                    style: Theme.of(context).textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                );
              },
            ),
            const SizedBox(height: AppSpacing.xxl),
            FilledButton.icon(
              onPressed: () => setState(() => currentStage = ClaimStage.initial),
              icon: const Icon(Icons.explore),
              label: const Text('Keep exploring'),
            ),
          ],
        ),
      ),
        ),
      ],
    );
  }
}
