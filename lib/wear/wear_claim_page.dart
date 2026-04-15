import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/app_preferences.dart';
import 'package:postbox_game/location_service.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/streak_service.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/wear/wear_theme.dart';

enum _ClaimStage { ready, scanning, found, empty, quiz, claiming, success }

/// Simplified claim flow for Wear OS.
///
/// Scan → quiz (2 options) → claim → success with haptic feedback.
/// No confetti or complex animations — optimised for small screen and battery.
class WearClaimPage extends StatefulWidget {
  const WearClaimPage({super.key});

  @override
  State<WearClaimPage> createState() => _WearClaimPageState();
}

class _WearClaimPageState extends State<WearClaimPage> {
  _ClaimStage _stage = _ClaimStage.ready;
  int _count = 0;
  int _claimedToday = 0;
  Map<String, dynamic> _postboxes = {};
  String? _quizCipher;
  List<String> _quizOptions = [];
  int _pointsEarned = 0;
  int _claimedCount = 0;

  final HttpsCallable _nearbyCallable =
      FirebaseFunctions.instance.httpsCallable('nearbyPostboxes');
  final HttpsCallable _claimCallable =
      FirebaseFunctions.instance.httpsCallable('startScoring');
  final StreakService _streakService = StreakService();
  late final Stream<int?> _streakStream = _streakService.streakStream();

  Future<void> _scan() async {
    if (_stage == _ClaimStage.scanning) return;
    setState(() => _stage = _ClaimStage.scanning);
    Analytics.scanStarted();
    try {
      final position = await getPosition();
      final result = await _nearbyCallable.call(<String, dynamic>{
        'lat': position.latitude,
        'lng': position.longitude,
        'meters': AppPreferences.claimRadiusMeters,
      });
      if (!mounted) return;
      final counts = result.data['counts'] ?? {};
      final total = (counts['total'] as int?) ?? 0;
      final claimed = (counts['claimedToday'] as int?) ?? 0;
      _postboxes = Map<String, dynamic>.from(result.data['postboxes'] ?? {});
      setState(() {
        _count = total;
        _claimedToday = claimed;
        _stage = total > 0 ? _ClaimStage.found : _ClaimStage.empty;
      });
      if (total > 0) {
        HapticFeedback.lightImpact();
      }
    } catch (e) {
      debugPrint('Wear claim scan error: $e');
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() => _stage = _ClaimStage.empty);
    }
  }

  void _startQuiz() {
    final cipher = _pickQuizCipher();
    if (cipher == null) {
      _claimPostbox();
      return;
    }
    Analytics.quizStarted(cipher: cipher);
    setState(() {
      _quizCipher = cipher;
      _quizOptions = _buildQuizOptions(cipher);
      _stage = _ClaimStage.quiz;
    });
  }

  String? _pickQuizCipher() {
    final ciphers = <String>[];
    for (final p in _postboxes.values) {
      final map = p as Map<dynamic, dynamic>;
      if (map['claimedToday'] == true) continue;
      final monarch = map['monarch'];
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

  /// Build 2 quiz options for watch (correct + 1 random distractor).
  List<String> _buildQuizOptions(String correct) {
    final pool = List<String>.from(MonarchInfo.all)
      ..remove(correct)
      ..shuffle();
    return ([correct, pool.first]..shuffle());
  }

  void _onQuizAnswer(String answer) {
    if (answer == _quizCipher) {
      Analytics.quizCorrect(cipher: _quizCipher!);
      HapticFeedback.lightImpact();
      _claimPostbox();
    } else {
      Analytics.quizIncorrect(
        correctCipher: _quizCipher!,
        selectedCipher: answer,
      );
      HapticFeedback.heavyImpact();
      // Reshuffle and let them try again.
      setState(() {
        _quizOptions = _buildQuizOptions(_quizCipher!);
      });
    }
  }

  Future<void> _claimPostbox() async {
    setState(() => _stage = _ClaimStage.claiming);
    try {
      final position = await getPosition();
      final result = await _claimCallable.call(<String, dynamic>{
        'lat': position.latitude,
        'lng': position.longitude,
      });
      final found = result.data?['found'] == true;
      final allClaimedToday = result.data?['allClaimedToday'] == true;
      final rawClaimed = result.data?['claimed'] ?? 0;
      final claimedCount =
          rawClaimed is int ? rawClaimed : (rawClaimed as num).toInt();
      final points = result.data?['points'] ?? 0;
      final earnedPts = points is int ? points : (points as num).toInt();

      if (!found || allClaimedToday || claimedCount == 0) {
        Analytics.claimFailed(
          reason: !found ? 'out_of_range' : 'already_claimed_today',
        );
        if (!mounted) return;
        HapticFeedback.heavyImpact();
        // Return to ready state — user can rescan.
        setState(() => _stage = _ClaimStage.ready);
        return;
      }

      Analytics.claimSuccess(
          pointsEarned: earnedPts, claimedCount: claimedCount);
      if (!mounted) return;
      // Success haptic — double tap.
      HapticFeedback.mediumImpact();
      Future.delayed(const Duration(milliseconds: 100), () {
        HapticFeedback.lightImpact();
      });
      setState(() {
        _pointsEarned = earnedPts;
        _claimedCount = claimedCount;
        _stage = _ClaimStage.success;
      });
    } catch (e) {
      debugPrint('Wear claim error: $e');
      Analytics.claimFailed(reason: 'error');
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() => _stage = _ClaimStage.ready);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    switch (_stage) {
      case _ClaimStage.ready:
        return _buildReady(context);
      case _ClaimStage.scanning:
      case _ClaimStage.claiming:
        return _buildLoading(context);
      case _ClaimStage.found:
        return _buildFound(context);
      case _ClaimStage.empty:
        return _buildEmpty(context);
      case _ClaimStage.quiz:
        return _buildQuiz(context);
      case _ClaimStage.success:
        return _buildSuccess(context);
    }
  }

  Widget _buildReady(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.pin_drop,
            size: 36,
            color: postalRed.withValues(alpha: 0.7),
          ),
          const SizedBox(height: WearSpacing.md),
          FilledButton(
            onPressed: _scan,
            child: const Text('Scan & Claim'),
          ),
          const SizedBox(height: WearSpacing.sm),
          Text(
            'Within ${AppPreferences.claimRadiusMeters}m',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildLoading(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2, color: postalRed),
          ),
          const SizedBox(height: WearSpacing.md),
          Text(
            _stage == _ClaimStage.claiming ? 'Claiming...' : 'Scanning...',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _buildFound(BuildContext context) {
    final available = _count - _claimedToday;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.location_on, size: 28, color: postalRed),
          const SizedBox(height: WearSpacing.sm),
          Text(
            '$available postbox${available == 1 ? '' : 'es'}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (_claimedToday > 0 && _claimedToday == _count) ...[
            const SizedBox(height: WearSpacing.sm),
            Text(
              'All claimed today',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.orange),
            ),
          ] else ...[
            const SizedBox(height: WearSpacing.lg),
            FilledButton(
              onPressed: _startQuiz,
              child: const Text('Claim!'),
            ),
          ],
          const SizedBox(height: WearSpacing.sm),
          TextButton(
            onPressed: _scan,
            child: const Text('Rescan'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.location_off,
            size: 32,
            color: Colors.white.withValues(alpha: 0.3),
          ),
          const SizedBox(height: WearSpacing.md),
          Text(
            'None nearby',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: WearSpacing.lg),
          FilledButton(
            onPressed: _scan,
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }

  Widget _buildQuiz(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WearSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Which cipher?',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: WearSpacing.lg),
            for (final code in _quizOptions) ...[
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => _onQuizAnswer(code),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        code,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        MonarchInfo.labels[code] ?? code,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: WearSpacing.sm),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSuccess(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.check_circle,
            size: 48,
            color: Color(0xFF2E7D32),
          ),
          const SizedBox(height: WearSpacing.md),
          Text(
            _claimedCount > 1
                ? '$_claimedCount claimed!'
                : 'Claimed!',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          if (_pointsEarned > 0) ...[
            const SizedBox(height: WearSpacing.sm),
            Text(
              '+$_pointsEarned pts',
              style: const TextStyle(
                color: postalGold,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ],
          // Streak display
          StreamBuilder<int?>(
            stream: _streakStream,
            builder: (context, snap) {
              final streak = snap.data ?? 0;
              if (streak <= 0) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: WearSpacing.sm),
                child: Text(
                  streak == 1 ? 'Streak started!' : '$streak-day streak!',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              );
            },
          ),
          const SizedBox(height: WearSpacing.lg),
          TextButton(
            onPressed: () => setState(() => _stage = _ClaimStage.ready),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}
