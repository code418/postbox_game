import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:postbox_game/firebase_functions_eu.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/services/claim_outbox.dart';
import 'package:postbox_game/services/device_id_service.dart';
import 'package:postbox_game/location_service.dart';
import 'package:postbox_game/maintenance_guard.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/streak_service.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/wear/wear_error_messages.dart';
import 'package:postbox_game/wear/wear_theme.dart';
import 'package:postbox_game/widgets/quiz_helpers.dart';

enum _ClaimStage { ready, scanning, found, empty, error, quiz, claiming, success }

/// Maps a [FirebaseFunctionsException] code from the `startScoring` callable to
/// a short, watch-appropriate error message.
///
/// Extracted as a pure top-level function so this native-edge mapping — which
/// deliberately diverges from the phone claim sheet's longer copy — is
/// unit-testable without driving the platform-channel claim flow. Mirrors how
/// `freshStreak` and the `quiz_helpers` are shared and pinned by tests so the
/// Wear path can't silently drift from the phone path. `failed-precondition`
/// is the server's travel-speed anti-spoof rejection.
String wearClaimErrorMessage(String code) => switch (code) {
      'failed-precondition' => 'Too fast. Slow down.',
      'unavailable' => 'No connection.',
      _ => 'Claim failed',
    };

/// Simplified claim flow for Wear OS.
///
/// Scan → quiz (2 options) → claim → success with haptic feedback.
/// No confetti or complex animations — optimised for small screen and battery.
///
/// Scanning works signed out (discovery is auth-free server-side); claiming
/// does not. When [signedIn] is false the claim CTA becomes "Sign in to
/// claim" and fires [onSignInRequested] (the shell swipes to its sign-in
/// page) instead of starting the quiz.
class WearClaimPage extends StatefulWidget {
  const WearClaimPage({
    super.key,
    required this.signedIn,
    this.onSignInRequested,
  });

  final bool signedIn;
  final VoidCallback? onSignInRequested;

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
      appFunctions.httpsCallable('nearbyPostboxes');
  final HttpsCallable _claimCallable =
      appFunctions.httpsCallable('startScoring');
  final StreakService _streakService = StreakService();

  /// Created on first claim success rather than at mount, so it binds to the
  /// uid that actually claimed — this page can now be mounted signed-out.
  /// (The shell also remounts on auth changes; this is defence-in-depth so
  /// the stream's correctness doesn't silently depend on the parent's key.)
  Stream<int?>? _streakStream;

  Future<void> _scan() async {
    if (_stage == _ClaimStage.scanning) return;
    setState(() {
      _stage = _ClaimStage.scanning;
      _errorMessage = null;
    });
    Analytics.scanStarted();
    try {
      final position = await getPosition(forceLocationManager: true);
      // Read-only scan: safe to retry wholesale on a transport flake.
      final result =
          await retryOnUnavailable(() => _nearbyCallable.call(<String, dynamic>{
                'lat': position.latitude,
                'lng': position.longitude,
                'meters': RemoteConfigService.instance.claimRadiusMeters,
              }));
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
        _errorMessage = wearLocationErrorMessage(e.kind, action: 'scan');
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

  void _startQuiz() {
    if (!widget.signedIn) {
      // Claiming needs an account; the found-view CTA already says so — this
      // guard is belt-and-braces for any other path into the quiz.
      widget.onSignInRequested?.call();
      return;
    }
    final valid = collectValidQuizCiphers(_postboxes.values);
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
      // Watch screen is tiny — show only 2 options vs the phone's 4.
      _quizOptions = buildQuizOptions(valid, maxOptions: 2);
      _quizMissed = false;
      _stage = _ClaimStage.quiz;
    });
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
        _quizOptions = buildQuizOptions(_validQuizCiphers, maxOptions: 2);
        _quizMissed = true;
      });
    }
  }

  Future<void> _claimPostbox() async {
    if (!widget.signedIn) {
      widget.onSignInRequested?.call();
      return;
    }
    // Maintenance gate. The phone routes every write through
    // MaintenanceGuard.blocked(), whose own doc notes it is the ONLY gate —
    // `startScoring` has no server-side maintenance check (unlike
    // flushOfflineClaims, which re-checks because it can't rely on a client).
    // The watch had no gate at all, so a maintenance window meant to stop
    // writes (e.g. a Firestore migration) did not stop claims from a watch.
    // MaintenanceGuard.blocked() shows a SnackBar, which is wrong on a round
    // watch face, so read the flag and use the watch's own error stage.
    if (MaintenanceGuard.isOn) {
      HapticFeedback.heavyImpact();
      setState(() {
        _stage = _ClaimStage.error;
        _errorMessage = 'Paused for maintenance';
      });
      return;
    }
    setState(() {
      _stage = _ClaimStage.claiming;
      _errorMessage = null;
    });
    try {
      final position = await getPosition(forceLocationManager: true);
      final deviceIdHash = await DeviceIdService.get();
      // One id per logical claim attempt, exactly as the phone claim sheet
      // does. A watch's tethered link drops far more readily than a phone's,
      // and without this a dropped RESPONSE meant the claim was recorded
      // server-side while the watch showed "Claim failed" — and the rescan
      // that follows hits startScoring's already-claimed fast path, so the
      // user never saw the points they had earned. With the id the server
      // replays the stored response instead (functions/src/_attempts.ts),
      // which is also what makes the auto-retry below safe on a WRITE call.
      final attemptId = newAttemptId();
      final result =
          await retryOnUnavailable(() => _claimCallable.call(<String, dynamic>{
                'lat': position.latitude,
                'lng': position.longitude,
                // Client wall-clock for the shadow-mode out-of-window anomaly
                // signal.
                'clientTsMs': DateTime.now().millisecondsSinceEpoch,
                // Stable per-install id for the shadow-mode repeated-device
                // signal (omitted when unavailable so the server never sees a
                // null).
                if (deviceIdHash != null) 'deviceIdHash': deviceIdHash,
                'attemptId': attemptId,
              }));
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
      // Bind the streak stream to the uid that just claimed (see field doc).
      _streakStream ??= _streakService.streakStream();
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
        _errorMessage = wearLocationErrorMessage(e.kind, action: 'claim');
      });
    } on FirebaseFunctionsException catch (e) {
      // Mirror the phone claim sheet: the server's travel-speed anti-spoof
      // check throws `failed-precondition`, which should tell the user to slow
      // down rather than render as a generic "Claim failed".
      debugPrint('Wear claim error: ${e.code} ${e.message}');
      Analytics.claimFailed(reason: e.code);
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() {
        _stage = _ClaimStage.error;
        _errorMessage = wearClaimErrorMessage(e.code);
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
            'Within ${RemoteConfigService.instance.claimRadiusMeters}m',
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
            // Signed out the CTA routes to the sign-in page — the scan result
            // stays visible so the user knows what signing in unlocks.
            FilledButton(
              onPressed: widget.signedIn
                  ? _startQuiz
                  : () => widget.onSignInRequested?.call(),
              child: Text(widget.signedIn ? 'Claim!' : 'Sign in to claim'),
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
