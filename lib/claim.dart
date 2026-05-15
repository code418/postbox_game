import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/app_preferences.dart';
import 'package:postbox_game/james_controller.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/location_service.dart';
import 'package:postbox_game/streak_service.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/widgets/claim_quiz_sheet.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Stage enum
// ─────────────────────────────────────────────────────────────────────────────

/// The three top-level states owned by the [Claim] screen.
///
/// Everything from `searching` onward is managed by [ClaimQuizSheet].
enum ClaimStage { initial, scanning, quizzing }

// ─────────────────────────────────────────────────────────────────────────────
// Theme helpers
// ─────────────────────────────────────────────────────────────────────────────

Color _warning(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? AppColors.warningTextDark
    : AppColors.warningTextLight;

Color _error(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? AppColors.errorTextDark
    : AppColors.errorTextLight;

// ─────────────────────────────────────────────────────────────────────────────
// Widget
// ─────────────────────────────────────────────────────────────────────────────

class Claim extends StatefulWidget {
  const Claim({super.key, this.autoScan = false});

  /// When true, a scan is kicked off automatically on first build. Used by
  /// the Android home-screen widget deep-link.
  final bool autoScan;

  @override
  State<Claim> createState() => _ClaimState();
}

class _ClaimState extends State<Claim> {
  ClaimStage _stage = ClaimStage.initial;
  LatLng? _scanPosition;
  DistanceUnit _distanceUnit = DistanceUnit.meters;

  final StreakService _streakService = StreakService();
  // Cached so StreamBuilder doesn't re-subscribe on every rebuild.
  late final Stream<int?> _streakStream = _streakService.streakStream();

  @override
  void initState() {
    super.initState();
    AppPreferences.getDistanceUnit().then((unit) {
      if (mounted) setState(() => _distanceUnit = unit);
    });
    if (widget.autoScan) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_startScan());
      });
    }
  }

  // ── Location acquisition ──────────────────────────────────────────────────

  Future<void> _startScan() async {
    if (_stage != ClaimStage.initial) return;
    setState(() => _stage = ClaimStage.scanning);

    try {
      _distanceUnit = await AppPreferences.getDistanceUnit();
      final position = await getPosition();
      if (!mounted) return;
      setState(() {
        _scanPosition = LatLng(position.latitude, position.longitude);
        _stage = ClaimStage.quizzing;
      });
    } catch (e) {
      if (!mounted) return;
      final raw = e.toString();
      if (raw.contains('permanently denied')) {
        unawaited(Analytics.locationPermissionPermanentlyDenied());
        _showPermissionDeniedSnackBar();
      } else if (raw.contains('services are disabled')) {
        _showLocationServicesDisabledSnackBar();
      } else {
        _showErrorSnackBar(raw.startsWith('Exception: ')
            ? raw.replaceFirst('Exception: ', '')
            : 'Could not get your location. Please try again.');
      }
      final msg = raw.contains('permission')
          ? JamesMessages.nearbyErrorPermission.resolve()
          : JamesMessages.claimErrorGeneral.resolve();
      JamesController.of(context)?.show(msg);
      setState(() => _stage = ClaimStage.initial);
    }
  }

  // ── Quiz completion ───────────────────────────────────────────────────────

  /// Called by [ClaimQuizSheet] when the flow reaches any terminal state.
  /// Shows a brief SnackBar on success and resets to [ClaimStage.initial].
  void _onQuizCompleted(ClaimQuizResult result) {
    if (!mounted) return;
    if (result.claimedCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.claimedCount > 1
              ? '${result.claimedCount} postboxes claimed! +${result.pointsEarned} pts'
              : 'Postbox claimed! +${result.pointsEarned} pts'),
        ),
      );
    }
    _resetToInitial();
  }

  void _resetToInitial() {
    if (!mounted) return;
    setState(() {
      _stage = ClaimStage.initial;
      _scanPosition = null;
    });
  }

  // ── SnackBar helpers ───────────────────────────────────────────────────────

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: _error(context),
      ),
    );
  }

  void _showPermissionDeniedSnackBar() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Location permission permanently denied.'),
        backgroundColor: _error(context),
        action: SnackBarAction(
          label: 'Open Settings',
          textColor: Colors.white,
          onPressed: Geolocator.openAppSettings,
        ),
      ),
    );
  }

  void _showLocationServicesDisabledSnackBar() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Location services are disabled.'),
        backgroundColor: _error(context),
        action: SnackBarAction(
          label: 'Open Settings',
          textColor: Colors.white,
          onPressed: Geolocator.openLocationSettings,
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // While acquiring position, show a brief loading indicator so the user
    // gets immediate feedback on tap.
    if (_stage == ClaimStage.scanning) {
      return const Center(child: CircularProgressIndicator(color: postalRed));
    }

    // Once we have a position, hand off to ClaimQuizSheet for the full flow.
    if (_stage == ClaimStage.quizzing && _scanPosition != null) {
      return ClaimQuizSheet(
        scanPosition: _scanPosition!,
        onCompleted: _onQuizCompleted,
        onCancel: _resetToInitial,
      );
    }

    // Default: initial state with scan button + streak badge.
    return _buildInitial(context);
  }

  Widget _buildInitial(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.only(
          top: AppSpacing.xl,
          left: AppSpacing.xl,
          right: AppSpacing.xl,
          bottom: 100,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight - 100),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SvgPicture.asset(
                'assets/postbox.svg',
                height: 100,
                colorFilter:
                    const ColorFilter.mode(postalRed, BlendMode.srcIn),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Find a postbox to claim',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Stand within ${AppPreferences.formatShortDistance(AppPreferences.claimRadiusMeters, _distanceUnit)} of a postbox, then tap below to check if you can claim it.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                      color: _warning(context).withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: _warning(context).withValues(alpha: 0.40)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('🔥', style: TextStyle(fontSize: 16)),
                        const SizedBox(width: 6),
                        Text(
                          '$streak-day streak',
                          style: TextStyle(
                            color: _warning(context),
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
                onPressed: _startScan,
                icon: const Icon(Icons.radar),
                label: const Text('Scan for postboxes nearby'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
