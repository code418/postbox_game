import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:postbox_game/james_controller.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/theme.dart';

import 'route_session.dart';

/// Shown when the user arrives at the destination (or ends the route early).
///
/// Displays points earned, postboxes claimed, walking time, and pace.
/// Fires a confetti burst and a Postman James congratulation on first render.
class RouteCompletionScreen extends StatefulWidget {
  final RouteSession session;
  final int pointsEarned;
  final int claimedCount;

  /// Total elapsed walk/jog time in seconds.
  final int walkSeconds;

  const RouteCompletionScreen({
    super.key,
    required this.session,
    this.pointsEarned = 0,
    this.claimedCount = 0,
    this.walkSeconds = 0,
  });

  @override
  State<RouteCompletionScreen> createState() => _RouteCompletionScreenState();
}

class _RouteCompletionScreenState extends State<RouteCompletionScreen> {
  late final ConfettiController _confetti;
  bool _jamesShown = false;

  @override
  void initState() {
    super.initState();
    _confetti = ConfettiController(duration: const Duration(seconds: 3));
    _confetti.play();
  }

  @override
  void dispose() {
    _confetti.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Show James once — on the first frame after the screen is in the tree.
    if (!_jamesShown) {
      _jamesShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          JamesController.of(context)?.show(JamesMessages.routeArrival.resolve());
        }
      });
    }
  }

  // ── Time formatting ───────────────────────────────────────────────────────

  /// Formats [walkSeconds] as "MM min SS sec" or "H h MM min" when >= 1 hour.
  static String _formatTime(int totalSeconds) {
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;

    if (hours >= 1) {
      return '$hours h ${minutes.toString().padLeft(2, '0')} min';
    }
    return '${minutes.toString().padLeft(2, '0')} min ${seconds.toString().padLeft(2, '0')} sec';
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paceLabel =
        widget.session.pace == RoutePace.jog ? 'Jogging' : 'Walking';

    return Scaffold(
      appBar: AppBar(title: const Text('Route complete')),
      body: Stack(
        children: [
          // ── Main content ──────────────────────────────────────────────────
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: Column(
                children: [
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // ── Success icon ────────────────────────────────
                            Icon(
                              Icons.check_circle_rounded,
                              size: 80,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(height: AppSpacing.lg),

                            // ── Points headline ─────────────────────────────
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.lg,
                                vertical: AppSpacing.sm,
                              ),
                              decoration: BoxDecoration(
                                color: postalGold.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                '${widget.pointsEarned} points earned',
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  color: postalGold,
                                  fontWeight: FontWeight.bold,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.md),

                            // ── Claimed count ────────────────────────────────
                            Text(
                              widget.claimedCount == 1
                                  ? '1 postbox claimed'
                                  : '${widget.claimedCount} postboxes claimed',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: AppSpacing.sm),

                            // ── Walking time ─────────────────────────────────
                            Text(
                              'Walked for ${_formatTime(widget.walkSeconds)}',
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: AppSpacing.md),

                            // ── Pace chip ─────────────────────────────────────
                            Chip(
                              avatar: Icon(
                                widget.session.pace == RoutePace.jog
                                    ? Icons.directions_run
                                    : Icons.directions_walk,
                                size: 16,
                              ),
                              label: Text(paceLabel),
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // ── Bottom actions ──────────────────────────────────────────
                  const SizedBox(height: AppSpacing.md),
                  FilledButton(
                    onPressed: () =>
                        Navigator.popUntil(context, (r) => r.isFirst),
                    child: const Text('Done'),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextButton(
                    onPressed: () =>
                        Navigator.popUntil(context, (r) => r.isFirst),
                    child: const Text('Plan another route'),
                  ),
                  const SizedBox(height: kJamesStripClearance),
                ],
              ),
            ),
          ),

          // ── Confetti ──────────────────────────────────────────────────────
          Align(
            alignment: Alignment.topCenter,
            child: ConfettiWidget(
              confettiController: _confetti,
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
        ],
      ),
    );
  }
}
