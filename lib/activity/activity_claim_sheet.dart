import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:postbox_game/activity/activity_helpers.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/firebase_functions_eu.dart';
import 'package:postbox_game/james_controller.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/maintenance_guard.dart';
import 'package:postbox_game/services/activity_claims_service.dart';
import 'package:postbox_game/services/claim_events.dart';
import 'package:postbox_game/services/claim_outbox.dart';
import 'package:postbox_game/services/home_widget_service.dart';
import 'package:postbox_game/services/user_properties_publisher.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/widgets/cypher_quiz_options.dart';
import 'package:postbox_game/widgets/quiz_helpers.dart';

enum _Stage { quiz, noQuiz, wrong, claimed, networkError, settled }

/// The cypher quiz + claim for one workout candidate (the postboxes a recorded
/// walk/run passed together). Same rules as the live claim quiz: a correct
/// answer claims; a wrong one doesn't. Same attemptId discipline as
/// ClaimQuizSheet: a transport failure keeps the id so Retry replays the
/// server's stored answer; any definitive answer discards it.
class ActivityClaimSheet extends StatefulWidget {
  const ActivityClaimSheet({
    super.key,
    required this.candidate,
    this.service,
    this.james,
    this.afterClaim,
  });

  final ActivityCandidate candidate;
  final ActivityClaimsService? service;
  final JamesController? james;

  /// Post-claim side effects (widget refresh, analytics user properties).
  /// Injectable so widget tests needn't stand up Firestore.
  final Future<void> Function()? afterClaim;

  /// Shows the sheet; resolves with the claim outcome (null if dismissed).
  static Future<ActivityClaimOutcome?> show(
    BuildContext context,
    ActivityCandidate candidate, {
    JamesController? james,
    ActivityClaimsService? service,
  }) =>
      showModalBottomSheet<ActivityClaimOutcome>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => ActivityClaimSheet(candidate: candidate, james: james, service: service),
      );

  @override
  State<ActivityClaimSheet> createState() => _ActivityClaimSheetState();
}

class _ActivityClaimSheetState extends State<ActivityClaimSheet> {
  late final ActivityClaimsService _service = widget.service ?? ActivityClaimsService.instance;
  late final Set<String> _valid = collectValidQuizCiphers(
      widget.candidate.boxes.map((b) => <String, Object?>{'monarch': b.monarch, 'claimedToday': false}));
  late final List<String> _options = buildQuizOptions(_valid, maxOptions: 4);
  late _Stage _stage = _valid.isEmpty ? _Stage.noQuiz : _Stage.quiz;
  String? _selected;
  bool _busy = false;
  String? _attemptId;
  ActivityClaimOutcome? _outcome;

  ActivityCandidate get _c => widget.candidate;

  void _onAnswer(String code) {
    setState(() => _selected = code);
    if (_valid.contains(code)) {
      HapticFeedback.lightImpact();
      unawaited(_claim());
    } else {
      HapticFeedback.heavyImpact();
      unawaited(Analytics.activityClaim(outcome: 'quiz_failed'));
      setState(() => _stage = _Stage.wrong);
      widget.james?.show(JamesMessages.activityQuizFailed.resolve());
    }
  }

  Future<void> _claim({bool isRetry = false}) async {
    if (_busy) return;
    if (MaintenanceGuard.blocked(context, actionLabel: 'claim')) return;
    if (!isRetry || _attemptId == null) _attemptId = newAttemptId();
    setState(() => _busy = true);
    final outcome = await _service.claim(_c, attemptId: _attemptId!);
    // Only a transport failure may be retried with the same id.
    if (outcome.kind != ActivityClaimKind.transport) _attemptId = null;
    if (outcome.kind == ActivityClaimKind.claimed) {
      ClaimEvents.markClaimed();
      unawaited(Analytics.claimSuccess(
          pointsEarned: outcome.points, claimedCount: outcome.claimed, source: 'workout'));
      unawaited((widget.afterClaim ?? _defaultAfterClaim)());
      widget.james?.show(JamesMessages.activityClaimSuccess(outcome.claimed, outcome.points));
    } else if (outcome.kind == ActivityClaimKind.expired) {
      widget.james?.show(JamesMessages.activityExpired.resolve());
    } else if (outcome.kind == ActivityClaimKind.quotaExceeded) {
      widget.james?.show(JamesMessages.activityQuotaExceeded.resolve());
    } else if (outcome.kind == ActivityClaimKind.transport) {
      widget.james?.show(JamesMessages.errorOffline.resolve());
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _outcome = outcome;
      _stage = switch (outcome.kind) {
        ActivityClaimKind.claimed => _Stage.claimed,
        ActivityClaimKind.transport => _Stage.networkError,
        _ => _Stage.settled,
      };
    });
  }

  static Future<void> _defaultAfterClaim() async {
    unawaited(HomeWidgetService().refresh());
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) unawaited(publishUserPropertiesFromFirestore(uid));
  }

  Future<void> _skip() async {
    await _service.dismiss(_c);
    if (mounted) Navigator.of(context).pop();
  }

  String _dayLine() {
    final now = DateTime.now();
    String ymd(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    if (_c.claimDate == ymd(now)) return 'Counts for today.';
    if (_c.claimDate == ymd(now.subtract(const Duration(days: 1)))) {
      return "Counts for yesterday: your streak, weekly and lifetime totals (yesterday's daily board has closed).";
    }
    return 'Counts for ${_c.claimDate}.';
  }

  String _settledMessage(ActivityClaimOutcome o) => switch (o.kind) {
        ActivityClaimKind.alreadyClaimed => 'Already yours for that day.',
        ActivityClaimKind.notFound => "We couldn't confirm that one. It may have been moved or removed.",
        ActivityClaimKind.expired => 'That pass is too long ago to claim now.',
        ActivityClaimKind.quotaExceeded => "That's the most workout claims for today. Try again tomorrow.",
        ActivityClaimKind.notAvailable => "Workout claims aren't available right now.",
        ActivityClaimKind.maintenance => "We're doing a spot of maintenance. Try again shortly.",
        ActivityClaimKind.appVerification => appVerificationMessage,
        ActivityClaimKind.badToken => 'That workout needs checking again. Pull to refresh on the workouts screen.',
        _ => 'Could not claim that postbox. Please try again.',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = _c.boxes.length;
    final title = count == 1
        ? 'You passed this postbox at ${clockTime(_c.passedAtMs)}'
        : 'You passed $count postboxes at ${clockTime(_c.passedAtMs)}';
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              switch (_stage) {
                _Stage.claimed => Icons.check_circle,
                _Stage.networkError => Icons.wifi_off,
                _ => Icons.directions_run,
              },
              size: 48,
              color: _stage == _Stage.claimed ? theme.colorScheme.primary : postalRed,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'On your ${sessionNoun(_c.exerciseType)} · worth ${_c.totalPoints} '
              '${_c.totalPoints == 1 ? 'point' : 'points'}. ${_dayLine()}',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.lg),
            ..._body(context),
          ],
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    final theme = Theme.of(context);
    switch (_stage) {
      case _Stage.quiz:
        return [
          Text(
            _c.boxes.length == 1 ? 'Which cypher was on it?' : 'Which cypher was on one of them?',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.md),
          CypherQuizOptions(options: _options, selected: _selected, busy: _busy, onAnswer: _onAnswer),
          TextButton(onPressed: _busy ? null : _skip, child: const Text("I didn't spot it")),
        ];
      case _Stage.noQuiz:
        return [
          const Text("We don't know this box's cypher, so there's no quiz this time.",
              textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.md),
          FilledButton(
            onPressed: _busy ? null : _claim,
            child: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Claim it'),
          ),
        ];
      case _Stage.wrong:
        return [
          Text('Not quite. That cypher wasn\'t on ${_c.boxes.length == 1 ? 'it' : 'any of them'}.',
              textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.md),
          FilledButton(
            onPressed: () => setState(() {
              _selected = null;
              _stage = _Stage.quiz;
            }),
            child: const Text('Try again'),
          ),
          TextButton(onPressed: _skip, child: const Text("I didn't spot it")),
        ];
      case _Stage.claimed:
        final o = _outcome!;
        return [
          Text('Claimed! +${o.points} ${o.points == 1 ? 'point' : 'points'}',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: AppSpacing.md),
          FilledButton(onPressed: () => Navigator.of(context).pop(o), child: const Text('Lovely')),
        ];
      case _Stage.networkError:
        return [
          const Text("Couldn't reach the server. Your claim may already be in; Retry will tell us.",
              textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.md),
          FilledButton(
            onPressed: _busy ? null : () => _claim(isRetry: true),
            child: const Text('Retry'),
          ),
        ];
      case _Stage.settled:
        final o = _outcome!;
        return [
          Text(_settledMessage(o), textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.md),
          FilledButton(onPressed: () => Navigator.of(context).pop(o), child: const Text('OK')),
        ];
    }
  }
}
