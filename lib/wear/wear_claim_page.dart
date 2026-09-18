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
import 'package:postbox_game/wear/wear_labels.dart';
import 'package:postbox_game/services/claim_events.dart';
import 'package:postbox_game/services/home_widget_service.dart';
import 'package:postbox_game/streak_service.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/wear/wear_error_messages.dart';
import 'package:postbox_game/wear/wear_round_inset.dart';
import 'package:postbox_game/wear/wear_theme.dart';
import 'package:postbox_game/widgets/quiz_helpers.dart';

enum WearClaimStage {
  ready,
  scanning,
  found,
  empty,
  error,
  quiz,
  claiming,
  success
}

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
    this.autoScan = false,
  });

  final bool signedIn;
  final VoidCallback? onSignInRequested;

  /// Start scanning as soon as this page mounts. Set when the app was opened
  /// by a tile or complication tap, which is a request to scan rather than
  /// just to open the app. The shell is keyed on the tap, so each tap gives a
  /// fresh mount and therefore exactly one scan.
  final bool autoScan;

  @override
  State<WearClaimPage> createState() => _WearClaimPageState();
}

class _WearClaimPageState extends State<WearClaimPage> {
  @override
  void initState() {
    super.initState();
    if (widget.autoScan) {
      // Post-frame so the first build (and its round-fit layout) completes
      // before the scan's setState lands.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_scan());
      });
    }
  }

  WearClaimStage _stage = WearClaimStage.ready;
  int _count = 0;
  int _claimedToday = 0;
  Map<String, dynamic> _postboxes = {};
  String? _quizCipher;
  List<String> _quizOptions = [];
  int _pointsEarned = 0;
  int _claimedCount = 0;

  /// Short human-readable error message shown in the [WearClaimStage.error] view.
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
    if (_stage == WearClaimStage.scanning) return;
    setState(() {
      _stage = WearClaimStage.scanning;
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
        _stage = total > 0 ? WearClaimStage.found : WearClaimStage.empty;
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
        _stage = WearClaimStage.error;
        _errorMessage = wearLocationErrorMessage(e.kind, action: 'scan');
      });
    } catch (e) {
      debugPrint('Wear claim scan error: $e');
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() {
        _stage = WearClaimStage.error;
        _errorMessage = 'Scan failed';
      });
    } finally {
      // Safety net: ensure we never get permanently stuck on 'scanning' if
      // an unexpected Dart Error bypasses the catch block above.
      if (mounted && _stage == WearClaimStage.scanning) {
        setState(() => _stage = WearClaimStage.ready);
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
      _stage = WearClaimStage.quiz;
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
        _stage = WearClaimStage.error;
        _errorMessage = 'Paused for maintenance';
      });
      return;
    }
    setState(() {
      _stage = WearClaimStage.claiming;
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
          _stage = WearClaimStage.error;
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
      // Push the new streak/points to the tile and complications. Mirrors the
      // phone's post-claim refresh in claim_quiz_sheet.dart: a glanceable
      // surface still showing the pre-claim total is the thing a player is
      // most likely to look at next.
      unawaited(HomeWidgetService().refresh());
      // Anything showing claim-derived data (the Today glance) refetches.
      ClaimEvents.markClaimed();
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
        _stage = WearClaimStage.success;
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
        _stage = WearClaimStage.error;
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
        _stage = WearClaimStage.error;
        _errorMessage = wearClaimErrorMessage(e.code);
      });
    } catch (e) {
      debugPrint('Wear claim error: $e');
      Analytics.claimFailed(reason: 'error');
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      setState(() {
        _stage = WearClaimStage.error;
        _errorMessage = 'Claim failed';
      });
    } finally {
      // Safety net: ensure we never get permanently stuck on 'claiming' if
      // an unexpected Dart Error bypasses the catch block above.
      if (mounted && _stage == WearClaimStage.claiming) {
        setState(() => _stage = WearClaimStage.ready);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: WearClaimView(
        stage: _stage,
        signedIn: widget.signedIn,
        count: _count,
        claimedToday: _claimedToday,
        errorMessage: _errorMessage,
        quizOptions: _quizOptions,
        quizMissed: _quizMissed,
        pointsEarned: _pointsEarned,
        claimedCount: _claimedCount,
        streakStream: _streakStream,
        onScan: _scan,
        // Signed out the CTA routes to the sign-in page — the scan result
        // stays visible so the user knows what signing in unlocks.
        onClaim: widget.signedIn
            ? _startQuiz
            : () => widget.onSignInRequested?.call(),
        onQuizAnswer: _onQuizAnswer,
        onDone: () => setState(() => _stage = WearClaimStage.ready),
      ),
    );
  }
}

/// The claim page's rendering, one layout per [WearClaimStage].
///
/// Split from the state machine so every stage can be laid out in a widget
/// test without location, App Check or the callables — the round-screen fit
/// test (test/wear_round_fit_test.dart) renders each one at watch size.
class WearClaimView extends StatelessWidget {
  const WearClaimView({
    super.key,
    required this.stage,
    required this.signedIn,
    this.count = 0,
    this.claimedToday = 0,
    this.errorMessage,
    this.quizOptions = const [],
    this.quizMissed = false,
    this.pointsEarned = 0,
    this.claimedCount = 0,
    this.streakStream,
    required this.onScan,
    required this.onClaim,
    required this.onQuizAnswer,
    required this.onDone,
  });

  final WearClaimStage stage;
  final bool signedIn;
  final int count;
  final int claimedToday;
  final String? errorMessage;
  final List<String> quizOptions;
  final bool quizMissed;
  final int pointsEarned;
  final int claimedCount;
  final Stream<int?>? streakStream;
  final VoidCallback onScan;
  final VoidCallback onClaim;
  final ValueChanged<String> onQuizAnswer;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    // Every stage lays out inside the round display's inscribed square (~136
    // dp on a 192 dp watch), so the taller stages put their icon on the same
    // row as the headline rather than stacking a fifth row that would reach
    // the bezel.
    return WearRoundInset(child: _buildContent(context));
  }

  Widget _buildContent(BuildContext context) {
    switch (stage) {
      case WearClaimStage.ready:
        return _buildReady(context);
      case WearClaimStage.scanning:
      case WearClaimStage.claiming:
        return _buildLoading(context);
      case WearClaimStage.found:
        return _buildFound(context);
      case WearClaimStage.empty:
        return _buildEmpty(context);
      case WearClaimStage.error:
        return _buildError(context);
      case WearClaimStage.quiz:
        return _buildQuiz(context);
      case WearClaimStage.success:
        return _buildSuccess(context);
    }
  }

  Widget _buildError(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 24, color: Colors.red),
          const SizedBox(height: WearSpacing.sm),
          Text(
            errorMessage ?? 'Something went wrong',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: WearSpacing.md),
          FilledButton(
            onPressed: onScan,
            child: const Text('Try again'),
          ),
        ],
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
            onPressed: onScan,
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
            stage == WearClaimStage.claiming ? 'Claiming...' : 'Scanning...',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _buildFound(BuildContext context) {
    final available = count - claimedToday;
    final allClaimed = available <= 0;
    // When everything nearby is already claimed, show the total found count
    // rather than the available count: "0 postboxes" alongside "All claimed
    // today" reads as a contradiction (it implies nothing was found).
    final headlineCount = allClaimed ? count : available;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _headlineRow(
            context,
            const Icon(Icons.location_on, size: 20, color: postalRed),
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
            const SizedBox(height: WearSpacing.md),
            FilledButton(
              onPressed: onClaim,
              child: Text(signedIn ? 'Claim!' : 'Sign in to claim'),
            ),
          ],
          TextButton(
            onPressed: onScan,
            child: const Text('Rescan'),
          ),
        ],
      ),
    );
  }

  /// Icon and headline on one row: the tall stages can't afford a separate
  /// icon row inside the inscribed square.
  Widget _headlineRow(BuildContext context, Widget icon, String text,
      {TextStyle? style}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        const SizedBox(width: WearSpacing.sm),
        Text(text, style: style),
      ],
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
            onPressed: onScan,
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }

  Widget _buildQuiz(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // A miss is signalled by the title alone (red + heavy haptic);
          // there is no room for a second hint line under it.
          Text(
            quizMissed ? 'Not quite!' : 'Which cipher?',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: quizMissed ? Colors.red : null,
                ),
          ),
          const SizedBox(height: WearSpacing.md),
          for (final (i, code) in quizOptions.indexed) ...[
            if (i > 0) const SizedBox(height: WearSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => onQuizAnswer(code),
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
                      watchMonarchLabel(code),
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSuccess(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _headlineRow(
            context,
            const Icon(
              Icons.check_circle,
              size: 24,
              color: Color(0xFF2E7D32),
            ),
            claimedCount > 1 ? '$claimedCount claimed!' : 'Claimed!',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          if (pointsEarned > 0) ...[
            const SizedBox(height: WearSpacing.sm),
            Text(
              '+$pointsEarned pts',
              style: const TextStyle(
                color: postalGold,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ],
          // Streak display
          StreamBuilder<int?>(
            stream: streakStream,
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
          const SizedBox(height: WearSpacing.sm),
          TextButton(
            onPressed: onDone,
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}
