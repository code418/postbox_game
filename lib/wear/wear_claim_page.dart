import 'dart:async';

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

enum _ClaimStage { ready, scanning, found, empty, error, quiz, claiming, success }

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
  /// Short human-readable error message shown in the [_ClaimStage.error] view.
  /// Set whenever a scan or claim fails for a recoverable reason (location
  /// denied, services off, network down). Null when there's no active error.
  String? _errorMessage;

  final HttpsCallable _nearbyCallable =
      FirebaseFunctions.instance.httpsCallable('nearbyPostboxes');
  final HttpsCallable _claimCallable =
      FirebaseFunctions.instance.httpsCallable('startScoring');
  final StreakService _streakService = StreakService();
  late final Stream<int?> _streakStream = _streakService.streakStream();

  Future<void> _scan() async {
    if (_stage == _ClaimStage.scanning) return;
    setState(() {
      _stage = _ClaimStage.scanning;
      _errorMessage = null;
    });
    Analytics.scanStarted();
    try {
      final position = await getPosition(forceLocationManager: true);
      final result = await _nearbyCallable.call(<String, dynamic>{
        'lat': position.latitude,
        'lng': position.longitude,
        'meters': AppPreferences.claimRadiusMeters,
      });
      if (!mounted) return;
      final counts = result.data['counts'] ?? {};
      final points = (result.data['points'] as Map?) ?? const {};
      // Cloud Functions serialise JS numbers as either int or double; `as int?`
      // would throw on a double, so normalise via num.
      int asInt(dynamic v) => (v as num?)?.toInt() ?? 0;
      final total = asInt(counts['total']);
      final claimed = asInt(counts['claimedToday']);
      _postboxes = Map<String, dynamic>.from(result.data['postboxes'] ?? {});
      setState(() {
        _count = total;
        _claimedToday = claimed;
        _stage = total > 0 ? _ClaimStage.found : _ClaimStage.empty;
      });
      if (total > 0) {
        HapticFeedback.lightImpact();
        Analytics.scanComplete(
          count: total,
          claimedToday: claimed,
          minPoints: asInt(points['min']),
          maxPoints: asInt(points['max']),
        );
      } else {
        Analytics.scanEmpty();
      }
    } on LocationServiceException catch (e) {
      // Previously these landed in the generic catch and rendered as
      // "None nearby" — which is misleading when the actual cause is the
      // user denying location or having location services off. Surface a
      // brief message in the dedicated error state so they know to act.
      debugPrint('Wear claim location error: $e');
      if (e.kind == LocationErrorKind.permissionPermanentlyDenied) {
        unawaited(Analytics.locationPermissionPermanentlyDenied());
      }
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() {
        _stage = _ClaimStage.error;
        _errorMessage = switch (e.kind) {
          LocationErrorKind.servicesDisabled => 'Turn on location',
          LocationErrorKind.permissionPermanentlyDenied =>
            'Location denied. Enable in settings.',
          LocationErrorKind.permissionDenied => 'Location needed to scan',
        };
      });
    } catch (e) {
      debugPrint('Wear claim scan error: $e');
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() {
        _stage = _ClaimStage.error;
        _errorMessage = 'Scan failed';
      });
    } finally {
      // Safety net: ensure we never get permanently stuck on 'scanning' if
      // an unexpected Dart Error bypasses the catch block above.
      if (mounted && _stage == _ClaimStage.scanning) {
        setState(() => _stage = _ClaimStage.ready);
      }
    }
  }

  /// Distinct known ciphers currently on nearby unclaimed postboxes — any of
  /// these counts as a correct quiz answer.
  Set<String> _validQuizCiphers = const {};

  /// Set true after the first incorrect quiz answer so the quiz title can show
  /// a "Not quite" hint. Without this the watch only fires a heavy haptic on
  /// a wrong pick, leaving users unsure whether the tap registered.
  bool _quizMissed = false;

  Set<String> _collectValidCiphers() {
    final ciphers = <String>{};
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
    return ciphers;
  }

  void _startQuiz() {
    final valid = _collectValidCiphers();
    if (valid.isEmpty) {
      _claimPostbox();
      return;
    }
    final shuffled = valid.toList()..shuffle();
    final picked = shuffled.first;
    Analytics.quizStarted(cipher: picked);
    setState(() {
      _quizCipher = picked;
      _validQuizCiphers = valid;
      _quizOptions = _buildQuizOptions(valid);
      _quizMissed = false;
      _stage = _ClaimStage.quiz;
    });
  }

  /// Build 2 quiz options for the watch. With multiple nearby ciphers, the
  /// options include up to 2 of them so the user can pick the one they
  /// actually see; otherwise it's the picked cipher plus a random distractor.
  List<String> _buildQuizOptions(Set<String> validCiphers,
      {int maxOptions = 2}) {
    final valid = validCiphers.toList()..shuffle();
    final pickedValid = valid.take(maxOptions).toList();
    final pool = List<String>.from(MonarchInfo.all)
      ..removeWhere(pickedValid.contains)
      ..shuffle();
    final fillers = pool.take(maxOptions - pickedValid.length).toList();
    return ([...pickedValid, ...fillers]..shuffle());
  }

  void _onQuizAnswer(String answer) {
    if (_validQuizCiphers.contains(answer)) {
      Analytics.quizCorrect(cipher: answer);
      HapticFeedback.lightImpact();
      _claimPostbox();
    } else {
      Analytics.quizIncorrect(
        correctCipher: _quizCipher!,
        selectedCipher: answer,
      );
      HapticFeedback.heavyImpact();
      // Reshuffle and show a "Not quite" hint so the wrong tap is visible —
      // a heavy haptic alone leaves users unsure whether the tap registered.
      setState(() {
        _quizOptions = _buildQuizOptions(_validQuizCiphers);
        _quizMissed = true;
      });
    }
  }

  Future<void> _claimPostbox() async {
    setState(() {
      _stage = _ClaimStage.claiming;
      _errorMessage = null;
    });
    try {
      final position = await getPosition(forceLocationManager: true);
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

      if (!found) {
        // Out of range. Surface a clear message instead of silently dropping
        // back to the ready screen, which left the user unsure their tap
        // registered. The error view's "Try again" button rescans.
        Analytics.claimFailed(reason: 'out_of_range');
        if (!mounted) return;
        HapticFeedback.heavyImpact();
        setState(() {
          _stage = _ClaimStage.error;
          _errorMessage = 'Too far. Move closer.';
        });
        return;
      }
      if (allClaimedToday || claimedCount == 0) {
        // Already claimed today — re-scan so the view reflects the current
        // (all-claimed) state rather than silently returning to ready.
        Analytics.claimFailed(reason: 'already_claimed_today');
        if (!mounted) return;
        HapticFeedback.heavyImpact();
        await _scan();
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
    } on LocationServiceException catch (e) {
      debugPrint('Wear claim location error: $e');
      Analytics.claimFailed(reason: 'location_${e.kind.name}');
      if (e.kind == LocationErrorKind.permissionPermanentlyDenied) {
        unawaited(Analytics.locationPermissionPermanentlyDenied());
      }
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() {
        _stage = _ClaimStage.error;
        _errorMessage = switch (e.kind) {
          LocationErrorKind.servicesDisabled => 'Turn on location',
          LocationErrorKind.permissionPermanentlyDenied =>
            'Location denied. Enable in settings.',
          LocationErrorKind.permissionDenied => 'Location needed to claim',
        };
      });
    } catch (e) {
      debugPrint('Wear claim error: $e');
      Analytics.claimFailed(reason: 'error');
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() {
        _stage = _ClaimStage.error;
        _errorMessage = 'Claim failed';
      });
    } finally {
      // Safety net: ensure we never get permanently stuck on 'claiming' if
      // an unexpected Dart Error bypasses the catch block above.
      if (mounted && _stage == _ClaimStage.claiming) {
        setState(() => _stage = _ClaimStage.ready);
      }
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
      case _ClaimStage.error:
        return _buildError(context);
      case _ClaimStage.quiz:
        return _buildQuiz(context);
      case _ClaimStage.success:
        return _buildSuccess(context);
    }
  }

  Widget _buildError(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: WearSpacing.lg),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 32, color: Colors.red),
            const SizedBox(height: WearSpacing.md),
            Text(
              _errorMessage ?? 'Something went wrong',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WearSpacing.lg),
            FilledButton(
              onPressed: _scan,
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
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
    final allClaimed = available <= 0;
    // When everything nearby is already claimed, show the total found count
    // rather than the available count: "0 postboxes" alongside "All claimed
    // today" reads as a contradiction (it implies nothing was found).
    final headlineCount = allClaimed ? _count : available;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.location_on, size: 28, color: postalRed),
          const SizedBox(height: WearSpacing.sm),
          Text(
            '$headlineCount postbox${headlineCount == 1 ? '' : 'es'}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (allClaimed) ...[
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
            color: Colors.white.withValues(alpha: 0.7),
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
              _quizMissed ? 'Not quite!' : 'Which cipher?',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: _quizMissed ? Colors.red : null,
                  ),
            ),
            if (_quizMissed) ...[
              const SizedBox(height: WearSpacing.xs),
              Text(
                'Look again',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
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
