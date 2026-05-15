import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/app_preferences.dart';
import 'package:postbox_game/james_controller.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/location_service.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/reports/report_missing_postbox_screen.dart';
import 'package:postbox_game/services/home_widget_service.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/widgets/postbox_map.dart';
import 'package:postbox_game/widgets/postbox_marker.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Result type
// ─────────────────────────────────────────────────────────────────────────────

/// Carries the outcome of a complete claim-quiz flow back to the parent.
class ClaimQuizResult {
  const ClaimQuizResult({
    this.claimedCount = 0,
    this.pointsEarned = 0,
    this.quizFailed = false,
    this.empty = false,
  });

  /// How many postboxes were claimed in this scan (0 on failure/dismiss).
  final int claimedCount;

  /// Total points earned (0 if the user dismissed or failed the quiz).
  final int pointsEarned;

  /// True if the user picked the wrong cipher.
  final bool quizFailed;

  /// True if the scan found no postboxes within range.
  final bool empty;
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal state enum
// ─────────────────────────────────────────────────────────────────────────────

enum _QuizStage { searching, results, empty, quiz, quizFailed, claimed }

// ─────────────────────────────────────────────────────────────────────────────
// Theme helpers (file-private)
// ─────────────────────────────────────────────────────────────────────────────

Color _success(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? AppColors.successTextDark
    : AppColors.successTextLight;

Color _warning(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? AppColors.warningTextDark
    : AppColors.warningTextLight;

Color _error(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? AppColors.errorTextDark
    : AppColors.errorTextLight;

// ─────────────────────────────────────────────────────────────────────────────
// Widget
// ─────────────────────────────────────────────────────────────────────────────

/// A self-contained scan-and-quiz flow covering the `searching → results →
/// empty/quiz → quizFailed/claimed` states.
///
/// The parent is responsible for the `initial` state (the "Scan" button that
/// acquires a position and then renders this widget). This widget takes over
/// from the moment scanning starts and fires [onCompleted] when the flow
/// finishes (success, failure, or empty).
///
/// Layout: renders a [Column] (or scrollable content) without its own
/// [Scaffold] or [AppBar], so it can be embedded in either a full-screen
/// [Scaffold] body or a modal bottom sheet.
///
/// Set [compact] to `true` for the route-mode bottom-sheet variant, which
/// uses larger touch targets and extra bottom padding for one-handed reach.
class ClaimQuizSheet extends StatefulWidget {
  const ClaimQuizSheet({
    super.key,
    required this.scanPosition,
    required this.onCompleted,
    this.onCancel,
    this.compact = false,
    this.streakStream,
  });

  /// The geographic position to scan around (passed in from the Claim screen
  /// after it acquires the user's location, or from LiveRouteScreen).
  final LatLng scanPosition;

  /// Fired when the flow reaches a terminal state (claimed, quiz-failed,
  /// empty, or the user cancels out).
  final ValueChanged<ClaimQuizResult> onCompleted;

  /// Optional hook invoked when the user explicitly cancels (e.g. taps "Back"
  /// on the empty or quiz-failed state, or "Rescan location" which hands
  /// control back to the parent). If null, cancellation silently fires
  /// [onCompleted] with a zero-score result.
  final VoidCallback? onCancel;

  /// When `true`, scales up buttons and adds extra bottom padding for
  /// one-handed reach in the route-mode bottom sheet. Default: `false`.
  final bool compact;

  /// Optional streak stream supplied by the parent. When non-null the claimed
  /// screen shows a streak chip driven by this stream. Pass the parent's own
  /// cached stream so there is only one [StreakService] subscription at a time.
  /// When null the streak chip is omitted from [_buildClaimed].
  final Stream<int?>? streakStream;

  @override
  State<ClaimQuizSheet> createState() => _ClaimQuizSheetState();
}

class _ClaimQuizSheetState extends State<ClaimQuizSheet>
    with TickerProviderStateMixin {
  // ── Scan results ────────────────────────────────────────────────────────
  int _count = 0;
  int _maxPoints = 0;
  int _minPoints = 0;
  int _claimedToday = 0;
  Map<String, dynamic> _postboxes = {};
  DistanceUnit _distanceUnit = DistanceUnit.meters;

  // ── Quiz ─────────────────────────────────────────────────────────────────
  String? _quizCipher;
  String? _selectedAnswer;
  List<String> _quizOptions = [];

  // ── Claim result ─────────────────────────────────────────────────────────
  int _pointsEarned = 0;
  int _claimedCount = 0;
  bool _isClaiming = false;

  // ── State machine ─────────────────────────────────────────────────────────
  _QuizStage _stage = _QuizStage.searching;

  // ── Animations ────────────────────────────────────────────────────────────
  late AnimationController _successController;
  late Animation<double> _successScale;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;
  late ConfettiController _confettiController;

  // ── Services ──────────────────────────────────────────────────────────────
  final HttpsCallable _nearbyCallable =
      FirebaseFunctions.instance.httpsCallable('nearbyPostboxes');
  final HttpsCallable _claimCallable =
      FirebaseFunctions.instance.httpsCallable('startScoring');
  final HomeWidgetService _homeWidgetService = HomeWidgetService();

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
    _confettiController =
        ConfettiController(duration: const Duration(seconds: 3));
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnim =
        CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut);

    AppPreferences.getDistanceUnit().then((unit) {
      if (mounted) setState(() => _distanceUnit = unit);
    });

    // Kick off the scan immediately on first build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_runSearch());
    });
  }

  @override
  void dispose() {
    _successController.dispose();
    _pulseController.dispose();
    _confettiController.dispose();
    super.dispose();
  }

  // ── Search ────────────────────────────────────────────────────────────────

  Future<void> _runSearch() async {
    if (_stage != _QuizStage.searching) {
      setState(() => _stage = _QuizStage.searching);
    }

    Analytics.scanStarted();

    try {
      _distanceUnit = await AppPreferences.getDistanceUnit();

      final result = await _nearbyCallable.call(<String, dynamic>{
        'lat': widget.scanPosition.latitude,
        'lng': widget.scanPosition.longitude,
        'meters': AppPreferences.claimRadiusMeters,
      });

      if (!mounted) return;

      final data = Map<String, dynamic>.from(result.data as Map);
      final counts = Map<String, dynamic>.from(data['counts'] as Map);
      final points = Map<String, dynamic>.from(data['points'] as Map);
      final rawPostboxes = data['postboxes'] as Map? ?? {};
      final postboxes = <String, dynamic>{};
      for (final entry in rawPostboxes.entries) {
        postboxes[entry.key as String] =
            Map<String, dynamic>.from(entry.value as Map);
      }

      // Cloud Functions serialise JS numbers as either int or double;
      // assigning a double to a typed int field throws, so normalise via num.
      int asInt(dynamic v) => (v as num?)?.toInt() ?? 0;

      setState(() {
        _count = asInt(counts['total']);
        _maxPoints = asInt(points['max']);
        _minPoints = asInt(points['min']);
        _claimedToday = asInt(counts['claimedToday']);
        _postboxes = postboxes;
        _stage = _count > 0 ? _QuizStage.results : _QuizStage.empty;
      });

      if (_count > 0) {
        Analytics.scanComplete(
          count: _count,
          claimedToday: _claimedToday,
          minPoints: _minPoints,
          maxPoints: _maxPoints,
        );
        if (mounted && _claimedToday == _count) {
          JamesController.of(context)
              ?.show(JamesMessages.claimErrorAlreadyClaimed.resolve());
        }
      } else {
        Analytics.scanEmpty();
        if (mounted) {
          JamesController.of(context)
              ?.show(JamesMessages.claimScanEmpty.resolve());
        }
      }
    } on FirebaseFunctionsException catch (e) {
      debugPrint('Firebase functions error: ${e.code} ${e.message}');
      final isOffline = e.code == 'unavailable';
      _showErrorSnackBar(isOffline
          ? 'No internet connection. Please try again.'
          : 'Could not scan for postboxes. Please try again.');
      if (!mounted) return;
      JamesController.of(context)?.show(
        isOffline
            ? JamesMessages.errorOffline.resolve()
            : JamesMessages.claimErrorGeneral.resolve(),
      );
      _cancel();
    } on TimeoutException {
      _showErrorSnackBar(
          'GPS signal timed out. Move to an open area and try again.');
      if (!mounted) return;
      JamesController.of(context)
          ?.show(JamesMessages.claimErrorGeneral.resolve());
      _cancel();
    } catch (e) {
      debugPrint('Error scanning: $e');
      final raw = e.toString();
      if (raw.contains('permanently denied')) {
        unawaited(Analytics.locationPermissionPermanentlyDenied());
        _showPermissionDeniedSnackBar();
      } else if (raw.contains('services are disabled')) {
        _showLocationServicesDisabledSnackBar();
      } else {
        _showErrorSnackBar(raw.startsWith('Exception: ')
            ? raw.replaceFirst('Exception: ', '')
            : 'Could not scan for postboxes. Please try again.');
      }
      if (!mounted) return;
      final msg = raw.contains('permission')
          ? JamesMessages.nearbyErrorPermission.resolve()
          : JamesMessages.claimErrorGeneral.resolve();
      JamesController.of(context)?.show(msg);
      _cancel();
    } finally {
      // Safety net: ensure we never get permanently stuck in 'searching' state.
      if (mounted && _stage == _QuizStage.searching) {
        _cancel();
      }
    }
  }

  // ── Claim ─────────────────────────────────────────────────────────────────

  Future<void> _claimPostbox() async {
    if (_isClaiming) return;
    setState(() => _isClaiming = true);
    HapticFeedback.mediumImpact();
    try {
      final position = await getPosition();
      final result = await _claimCallable.call(<String, dynamic>{
        'lat': position.latitude,
        'lng': position.longitude,
      });
      final claimData = Map<String, dynamic>.from(result.data as Map);
      final found = claimData['found'] == true;
      final allClaimedToday = claimData['allClaimedToday'] == true;
      final rawClaimed = claimData['claimed'] ?? 0;
      final claimedCount =
          rawClaimed is int ? rawClaimed : (rawClaimed as num).toInt();

      if (!found) {
        Analytics.claimFailed(reason: 'out_of_range');
        if (!mounted) return;
        setState(() => _isClaiming = false);
        JamesController.of(context)
            ?.show(JamesMessages.claimOutOfRange.resolve());
        // Re-run the search with the same position (postbox didn't move,
        // but the user may have drifted). The parent retains control.
        await _runSearch();
        return;
      }
      if (allClaimedToday || claimedCount == 0) {
        Analytics.claimFailed(reason: 'already_claimed_today');
        if (!mounted) return;
        setState(() => _isClaiming = false);
        _showErrorSnackBar('Already claimed today — come back tomorrow!');
        JamesController.of(context)
            ?.show(JamesMessages.claimErrorAlreadyClaimed.resolve());
        await _runSearch();
        return;
      }
      final points = claimData['points'] ?? 0;
      if (!mounted) return;
      final earnedPts =
          points is int ? points : (points as num).toInt();
      Analytics.claimSuccess(pointsEarned: earnedPts, claimedCount: claimedCount);
      setState(() {
        _pointsEarned = earnedPts;
        _claimedCount = claimedCount;
        _isClaiming = false;
        _stage = _QuizStage.claimed;
      });
      unawaited(_homeWidgetService.refresh());
      _successController.forward(from: 0);
      _confettiController.play();
      if (mounted) {
        final String msg;
        if (_claimedCount > 1) {
          msg = JamesMessages.claimSuccessMulti(_claimedCount, _pointsEarned);
        } else {
          final avgPts = _claimedCount > 0 ? _pointsEarned / _claimedCount : 0;
          msg = avgPts >= 7
              ? JamesMessages.claimSuccessRare.resolve()
              : JamesMessages.claimSuccessStandard.resolve();
        }
        JamesController.of(context)?.show(msg);
      }
    } on FirebaseFunctionsException catch (e) {
      debugPrint('Claim error: ${e.code} ${e.message}');
      Analytics.claimFailed(reason: e.code);
      final snackMsg = e.code == 'unavailable'
          ? 'No internet connection. Please try again.'
          : 'Could not claim postbox. Please try again.';
      _showErrorSnackBar(snackMsg);
      if (!mounted) return;
      setState(() => _isClaiming = false);
      final msg = (e.code == 'unavailable')
          ? JamesMessages.errorOffline.resolve()
          : JamesMessages.claimErrorGeneral.resolve();
      JamesController.of(context)?.show(msg);
    } catch (e) {
      debugPrint('Claim error: $e');
      final raw = e.toString();
      final isPermission = raw.contains('permission');
      final msg = isPermission
          ? JamesMessages.nearbyErrorPermission.resolve()
          : JamesMessages.claimErrorGeneral.resolve();
      if (raw.contains('permanently denied')) {
        unawaited(Analytics.locationPermissionPermanentlyDenied());
        _showPermissionDeniedSnackBar();
      } else if (raw.contains('services are disabled')) {
        _showLocationServicesDisabledSnackBar();
      } else {
        _showErrorSnackBar(isPermission
            ? raw.replaceFirst('Exception: ', '')
            : 'Could not claim postbox. Please try again.');
      }
      if (!mounted) return;
      setState(() => _isClaiming = false);
      JamesController.of(context)?.show(msg);
    } finally {
      if (mounted && _isClaiming) setState(() => _isClaiming = false);
    }
  }

  // ── Quiz helpers ──────────────────────────────────────────────────────────

  String? _pickQuizCipher() {
    final ciphers = <String>[];
    for (final p in _postboxes.values) {
      final map = p as Map<String, dynamic>;
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

  List<String> _buildQuizOptions(String correct) {
    final pool = List<String>.from(MonarchInfo.all)
      ..remove(correct)
      ..shuffle();
    return ([correct, ...pool.take(3)]..shuffle());
  }

  void _startQuiz() {
    final cipher = _pickQuizCipher();
    if (cipher == null) {
      unawaited(_claimPostbox());
      return;
    }
    Analytics.quizStarted(cipher: cipher);
    setState(() {
      _quizCipher = cipher;
      _quizOptions = _buildQuizOptions(cipher);
      _selectedAnswer = null;
      _stage = _QuizStage.quiz;
    });
  }

  void _onQuizAnswer(String answer) {
    setState(() => _selectedAnswer = answer);
    if (answer == _quizCipher) {
      Analytics.quizCorrect(cipher: _quizCipher!);
      HapticFeedback.lightImpact();
      unawaited(_claimPostbox());
    } else {
      Analytics.quizIncorrect(
        correctCipher: _quizCipher!,
        selectedCipher: answer,
      );
      HapticFeedback.heavyImpact();
      setState(() => _stage = _QuizStage.quizFailed);
      if (mounted) {
        JamesController.of(context)?.show(JamesMessages.quizFailed.resolve());
      }
    }
  }

  // ── Cancel / completion ────────────────────────────────────────────────────

  void _cancel() {
    if (widget.onCancel != null) {
      widget.onCancel!();
    } else {
      widget.onCompleted(const ClaimQuizResult());
    }
  }

  void _completeSuccess() {
    widget.onCompleted(ClaimQuizResult(
      claimedCount: _claimedCount,
      pointsEarned: _pointsEarned,
    ));
  }

  void _completeEmpty() {
    widget.onCompleted(const ClaimQuizResult(empty: true));
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

  // ── Layout constants ──────────────────────────────────────────────────────

  double get _bottomPad => widget.compact ? 120.0 : kJamesStripClearance;
  double get _buttonHeight => widget.compact ? 60.0 : 52.0;
  double get _optionHeight => widget.compact ? 68.0 : 56.0;

  // ── Map helper ─────────────────────────────────────────────────────────────

  Widget _claimRadiusMap({bool scanning = false, bool success = false}) {
    final center = widget.scanPosition;
    if (scanning) {
      return AnimatedBuilder(
        animation: _pulseAnim,
        builder: (_, __) {
          final alpha = 0.35 + _pulseAnim.value * 0.45;
          final strokeWidth = 2.0 + _pulseAnim.value * 3.0;
          return Card(
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              height: 180,
              child: PostboxMap(
                center: center,
                zoom: 17,
                interactionOptions:
                    const InteractionOptions(flags: InteractiveFlag.none),
                circleMarkers: [
                  CircleMarker(
                    point: center,
                    radius: AppPreferences.claimRadiusMeters,
                    useRadiusInMeter: true,
                    color: postalRed.withValues(alpha: 0.1),
                    borderColor:
                        postalRed.withValues(alpha: 0.4 + alpha * 0.5),
                    borderStrokeWidth: strokeWidth,
                  ),
                ],
                markers: [userPositionMarker(center)],
                bottomPadding: 0,
              ),
            ),
          );
        },
      );
    }
    final mutedFill = Theme.of(context).brightness == Brightness.dark
        ? AppColors.mutedTextDark
        : AppColors.mutedTextLight;
    final borderColor = success
        ? postalGold.withValues(alpha: 0.7)
        : mutedFill.withValues(alpha: 0.6);
    final fillColor = success ? postalGold : mutedFill;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 180,
        child: PostboxMap(
          center: center,
          zoom: 17,
          interactionOptions:
              const InteractionOptions(flags: InteractiveFlag.none),
          circleMarkers: [
            CircleMarker(
              point: center,
              radius: AppPreferences.claimRadiusMeters,
              useRadiusInMeter: true,
              color: fillColor.withValues(alpha: 0.12),
              borderColor: borderColor,
              borderStrokeWidth: 3,
            ),
          ],
          markers: [userPositionMarker(center)],
          bottomPadding: 0,
        ),
      ),
    );
  }

  // ── All-claimed banner ─────────────────────────────────────────────────────

  Widget _buildAllClaimedBanner(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: _warning(context).withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _warning(context).withValues(alpha: 0.40)),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_clock, color: _warning(context)),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Already claimed today',
                  style: TextStyle(
                      color: _warning(context), fontWeight: FontWeight.w600),
                ),
                Text(
                  'Resets at midnight · London time',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: _warning(context)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case _QuizStage.searching:
        return _buildSearching(context);
      case _QuizStage.results:
        return _buildResults(context);
      case _QuizStage.empty:
        return _buildEmpty(context);
      case _QuizStage.quiz:
        return _buildQuiz(context);
      case _QuizStage.quizFailed:
        return _buildQuizFailed(context);
      case _QuizStage.claimed:
        return _buildClaimed(context);
    }
  }

  // ── Stage builders ────────────────────────────────────────────────────────

  Widget _buildSearching(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.lg, AppSpacing.md, _bottomPad),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _claimRadiusMap(scanning: true),
          const SizedBox(height: AppSpacing.md),
          const CircularProgressIndicator(color: postalRed),
          const SizedBox(height: AppSpacing.md),
          Text(
              'Scanning within ${AppPreferences.formatShortDistance(AppPreferences.claimRadiusMeters, _distanceUnit)}...'),
        ],
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: EdgeInsets.only(
          top: AppSpacing.xl,
          left: AppSpacing.xl,
          right: AppSpacing.xl,
          bottom: _bottomPad,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight - _bottomPad),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _claimRadiusMap(),
              const SizedBox(height: AppSpacing.md),
              Icon(Icons.location_off,
                  size: 80,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.2)),
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
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xl),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ReportMissingPostboxScreen(
                      // Convert LatLng back to a null Position; the screen
                      // will use its own live-GPS fix as the authoritative
                      // location. Pass null so it doesn't prefill with stale
                      // coords — the user is already in this area anyway.
                      initialPosition: null,
                    ),
                  ),
                ),
                icon: const Icon(Icons.report_gmailerrorred_outlined),
                label: const Text('Report a missing postbox'),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: () {
                  _completeEmpty();
                },
                child: const Text('Back'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    return Stack(
      children: [
        ListView(
          padding: EdgeInsets.only(
            top: AppSpacing.md,
            bottom: _bottomPad + 64,
          ),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
              child:
                  _claimRadiusMap(success: _claimedToday < _count),
            ),
            _summaryCard(context),
            const SizedBox(height: AppSpacing.sm),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: OutlinedButton.icon(
                onPressed: _isClaiming ? null : _cancel,
                icon: const Icon(Icons.refresh),
                label: const Text('Rescan location'),
                style: OutlinedButton.styleFrom(
                  minimumSize: Size(double.infinity, _buttonHeight),
                ),
              ),
            ),
          ],
        ),
        Positioned(
          left: AppSpacing.md,
          right: AppSpacing.md,
          bottom: _bottomPad,
          child: _claimedToday == _count
              ? _buildAllClaimedBanner(context)
              : AbsorbPointer(
                  absorbing: _isClaiming,
                  child: FilledButton.icon(
                    onPressed: _isClaiming ? null : _startQuiz,
                    style: FilledButton.styleFrom(
                      minimumSize: Size(double.infinity, _buttonHeight),
                    ),
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
                    label: Text(_isClaiming
                        ? 'Claiming...'
                        : (_count - _claimedToday) == 1
                            ? 'Claim this postbox!'
                            : 'Claim ${_count - _claimedToday} postboxes!'),
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
                color: postalRed.withValues(alpha: 0.1),
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
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
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
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: EdgeInsets.only(
          top: AppSpacing.xl,
          left: AppSpacing.xl,
          right: AppSpacing.xl,
          bottom: _bottomPad,
        ),
        child: ConstrainedBox(
          constraints:
              BoxConstraints(minHeight: constraints.maxHeight - _bottomPad),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.help_outline, size: 64, color: postalRed),
              const SizedBox(height: AppSpacing.md),
              Text(
                (_count - _claimedToday) == 1
                    ? 'What\'s the cipher on this postbox?'
                    : 'What\'s the cipher on one of the nearby postboxes?',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                (_count - _claimedToday) == 1
                    ? 'Look at the postbox and pick the correct royal cipher.'
                    : 'Look at one of the postboxes and pick its royal cipher.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                          ? _success(context).withValues(alpha: 0.10)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: OutlinedButton(
                      onPressed:
                          _isClaiming ? null : () => _onQuizAnswer(code),
                      style: OutlinedButton.styleFrom(
                        minimumSize: Size(double.infinity, _optionHeight),
                        side: BorderSide(
                          color: isCorrectSelected
                              ? _success(context)
                              : (Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? AppColors.brandTextDark
                                  : AppColors.brandTextLight),
                          width: isCorrectSelected ? 2 : 1,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (isCorrectSelected) ...[
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: _success(context),
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
                                      ? _success(context)
                                      : null,
                                ),
                              ),
                              if (!isCorrectSelected)
                                Text(
                                  MonarchInfo.labels[code] ?? code,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant),
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
                    : () => setState(() => _stage = _QuizStage.results),
                child: const Text('Back'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuizFailed(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: EdgeInsets.only(
          top: AppSpacing.xl,
          left: AppSpacing.xl,
          right: AppSpacing.xl,
          bottom: _bottomPad,
        ),
        child: ConstrainedBox(
          constraints:
              BoxConstraints(minHeight: constraints.maxHeight - _bottomPad),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.cancel_outlined, size: 80, color: _error(context)),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Not quite!',
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Take another look at the cipher on the postbox and try again.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xl),
              FilledButton.icon(
                onPressed: () => setState(() => _stage = _QuizStage.results),
                style: FilledButton.styleFrom(
                  minimumSize: Size(double.infinity, _buttonHeight),
                ),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Try again'),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: _cancel,
                child: const Text('Rescan location'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildClaimed(BuildContext context) {
    return Stack(
      children: [
        LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: EdgeInsets.only(
              top: AppSpacing.xl,
              left: AppSpacing.xl,
              right: AppSpacing.xl,
              bottom: _bottomPad,
            ),
            child: ConstrainedBox(
              constraints:
                  BoxConstraints(minHeight: constraints.maxHeight - _bottomPad),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ScaleTransition(
                    scale: _successScale,
                    child: Icon(
                      Icons.check_circle,
                      size: 100,
                      color: _success(context),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    _claimedCount > 1
                        ? '$_claimedCount postboxes claimed!'
                        : 'Postbox claimed!',
                    style: Theme.of(context)
                        .textTheme
                        .headlineMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (_pointsEarned > 0)
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
                        '+$_pointsEarned points',
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(
                                color: postalGold,
                                fontWeight: FontWeight.bold),
                      ),
                    ),
                  if (widget.streakStream != null)
                    StreamBuilder<int?>(
                      stream: widget.streakStream,
                      builder: (context, snap) {
                        final streak = snap.data ?? 0;
                        if (streak <= 0) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.sm),
                          child: Text(
                            streak == 1
                                ? '🔥 Streak started!'
                                : '🔥 $streak-day streak!',
                            style: Theme.of(context).textTheme.titleMedium,
                            textAlign: TextAlign.center,
                          ),
                        );
                      },
                    ),
                  const SizedBox(height: AppSpacing.xxl),
                  FilledButton.icon(
                    onPressed: _completeSuccess,
                    style: FilledButton.styleFrom(
                      minimumSize: Size(double.infinity, _buttonHeight),
                    ),
                    icon: const Icon(Icons.explore),
                    label: const Text('Keep exploring'),
                  ),
                ],
              ),
            ),
          ),
        ),
        // Confetti is last in the Stack so it renders on top of the content.
        Align(
          alignment: Alignment.topCenter,
          child: ConfettiWidget(
            confettiController: _confettiController,
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
    );
  }
}
