import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/app_preferences.dart';
import 'package:postbox_game/james_controller.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/location_service.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/streak_service.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/widgets/postbox_map.dart';
import 'package:postbox_game/widgets/postbox_marker.dart';

enum ClaimStage { initial, searching, results, empty, quiz, quizFailed, claimed }

class Claim extends StatefulWidget {
  const Claim({super.key});

  @override
  ClaimState createState() => ClaimState();
}

class ClaimState extends State<Claim> with TickerProviderStateMixin {
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
  Position? _scanPosition;

  ClaimStage currentStage = ClaimStage.initial;

  late AnimationController _successController;
  late Animation<double> _successScale;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;
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
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnim = CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut);
    AppPreferences.getDistanceUnit().then((unit) {
      if (mounted) setState(() => _distanceUnit = unit);
    });
  }

  @override
  void dispose() {
    _successController.dispose();
    _pulseController.dispose();
    _confettiController.dispose();
    super.dispose();
  }

  final HttpsCallable _callable =
      FirebaseFunctions.instance.httpsCallable('nearbyPostboxes');
  final HttpsCallable _claimCallable =
      FirebaseFunctions.instance.httpsCallable('startScoring');
  final StreakService _streakService = StreakService();

  Future<void> _startSearch() async {
    // Guard against concurrent calls (e.g. pull-to-refresh + Refresh button
    // both firing before the next frame rebuilds the UI).
    if (currentStage == ClaimStage.searching) return;
    setState(() => currentStage = ClaimStage.searching);
    Analytics.scanStarted();
    try {
      _distanceUnit = await AppPreferences.getDistanceUnit();
      final position = await getPosition();
      if (mounted) setState(() => _scanPosition = position);
      final result = await _callable.call(<String, dynamic>{
        'lat': position.latitude,
        'lng': position.longitude,
        'meters': AppPreferences.claimRadiusMeters,
      });
      if (!mounted) return;
      setState(() {
        _count = result.data['counts']['total'] ?? 0;
        _maxPoints = result.data['points']['max'] ?? 0;
        _minPoints = result.data['points']['min'] ?? 0;
        _claimedToday = result.data['counts']['claimedToday'] ?? 0;
        _postboxes = Map<String, dynamic>.from(result.data['postboxes'] ?? {});
        currentStage = _count > 0 ? ClaimStage.results : ClaimStage.empty;
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
      setState(() => currentStage = ClaimStage.initial);
    } on TimeoutException {
      _showErrorSnackBar(
          'GPS signal timed out. Move to an open area and try again.');
      if (!mounted) return;
      JamesController.of(context)?.show(JamesMessages.claimErrorGeneral.resolve());
      setState(() => currentStage = ClaimStage.initial);
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
      setState(() => currentStage = ClaimStage.initial);
    } finally {
      // Safety net: ensure we never get permanently stuck in 'searching' state
      // if an unexpected Dart Error bypasses the catch blocks above.
      if (mounted && currentStage == ClaimStage.searching) {
        setState(() => currentStage = ClaimStage.initial);
      }
    }
  }

  Future<void> _claimPostbox() async {
    // Guard against concurrent calls (e.g. rapid double-tap before the frame
    // rebuild disables the button). _isClaiming is set synchronously inside
    // setState, so this check is effective even before the next build.
    if (_isClaiming) return;
    setState(() => _isClaiming = true);
    HapticFeedback.mediumImpact();
    try {
      final position = await getPosition();
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
        Analytics.claimFailed(reason: 'out_of_range');
        if (!mounted) return;
        setState(() => _isClaiming = false);
        JamesController.of(context)?.show(JamesMessages.claimOutOfRange.resolve());
        await _startSearch();
        return;
      }
      if (allClaimedToday || claimedCount == 0) {
        Analytics.claimFailed(reason: 'already_claimed_today');
        if (!mounted) return;
        setState(() => _isClaiming = false);
        _showErrorSnackBar('Already claimed today — come back tomorrow!');
        JamesController.of(context)?.show(JamesMessages.claimErrorAlreadyClaimed.resolve());
        await _startSearch();
        return;
      }
      final points = result.data?['points'] ?? 0;
      if (!mounted) return;
      final earnedPts = points is int ? points : (points as num).toInt();
      Analytics.claimSuccess(pointsEarned: earnedPts, claimedCount: claimedCount);
      setState(() {
        _pointsEarned = earnedPts;
        _claimedCount = claimedCount;
        _isClaiming = false;
        currentStage = ClaimStage.claimed;
      });
      _successController.forward(from: 0);
      _confettiController.play();
      // Streak update is performed server-side in startScoring (Admin SDK),
      // because Firestore rules restrict client writes on users/{uid} to
      // the friends array only. The streakStream in this widget reflects
      // the updated value via the existing Firestore listener.
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
          : (e.code == 'already-claimed')
              ? JamesMessages.claimErrorAlreadyClaimed.resolve()
              : (e.code == 'out-of-range')
                  ? JamesMessages.claimErrorOutOfRange.resolve()
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
      // Safety net: ensure _isClaiming is always cleared even if an unexpected
      // Dart Error (not Exception) bypasses the catch blocks above.
      if (mounted && _isClaiming) setState(() => _isClaiming = false);
    }
  }

  String? _pickQuizCipher() {
    // Collect all ciphers from unclaimed postboxes and pick randomly so the
    // quiz varies when multiple postboxes with different ciphers are nearby.
    final ciphers = <String>[];
    for (final p in _postboxes.values) {
      final map = p as Map<String, dynamic>;
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
      unawaited(_claimPostbox());
      return;
    }
    Analytics.quizStarted(cipher: cipher);
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
      Analytics.quizCorrect(cipher: _quizCipher!);
      HapticFeedback.lightImpact();
      unawaited(_claimPostbox());
    } else {
      Analytics.quizIncorrect(
        correctCipher: _quizCipher!,
        selectedCipher: answer,
      );
      HapticFeedback.heavyImpact();
      setState(() => currentStage = ClaimStage.quizFailed);
      if (mounted) {
        JamesController.of(context)
            ?.show(JamesMessages.quizFailed.resolve());
      }
    }
  }

  Widget _claimRadiusMap(Position position, {bool scanning = false, bool success = false}) {
    final center = LatLng(position.latitude, position.longitude);
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
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
                circleMarkers: [
                  CircleMarker(
                    point: center,
                    radius: AppPreferences.claimRadiusMeters,
                    useRadiusInMeter: true,
                    color: postalRed.withValues(alpha: 0.1),
                    borderColor: postalRed.withValues(alpha: 0.4 + alpha * 0.5),
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
    final borderColor = success
        ? postalGold.withValues(alpha: 0.7)
        : Colors.grey.withValues(alpha: 0.5);
    final fillColor = success ? postalGold : Colors.grey;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 180,
        child: PostboxMap(
          center: center,
          zoom: 17,
          interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
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

  Widget _buildAllClaimedBanner(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.35)),
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

  void _showPermissionDeniedSnackBar() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Location permission permanently denied.'),
        backgroundColor: Colors.red.shade700,
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
        backgroundColor: Colors.red.shade700,
        action: SnackBarAction(
          label: 'Open Settings',
          textColor: Colors.white,
          onPressed: Geolocator.openLocationSettings,
        ),
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
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                    color: Colors.orange.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.orange.withValues(alpha: 0.35)),
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
      ),
    );
  }

  Widget _buildSearching(BuildContext context) {
    final pos = _scanPosition;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md, AppSpacing.lg, AppSpacing.md, kJamesStripClearance),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (pos != null) ...[
            _claimRadiusMap(pos, scanning: true),
            const SizedBox(height: AppSpacing.md),
          ],
          const CircularProgressIndicator(color: postalRed),
          const SizedBox(height: AppSpacing.md),
          Text('Scanning within ${AppPreferences.formatShortDistance(AppPreferences.claimRadiusMeters, _distanceUnit)}...'),
        ],
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
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
            if (_scanPosition != null) ...[
              _claimRadiusMap(_scanPosition!),
              const SizedBox(height: AppSpacing.md),
            ],
            Icon(Icons.location_off, size: 80,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.2)),
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
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
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
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.only(
            top: AppSpacing.md,
            bottom: 164,
          ),
          children: [
            if (_scanPosition != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
                child: _claimRadiusMap(_scanPosition!, success: _claimedToday < _count),
              ),
            ],
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
          bottom: 100,
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
                          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
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
      padding: const EdgeInsets.only(
        top: AppSpacing.xl,
        left: AppSpacing.xl,
        right: AppSpacing.xl,
        // Extra clearance so the Back button doesn't hide behind the JamesStrip.
        bottom: 100,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight - 100),
        child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.help_outline, size: 64, color: postalRed),
          const SizedBox(height: AppSpacing.md),
          Text(
            (_count - _claimedToday) == 1
                ? 'What\'s the cipher on this postbox?'
                : 'What\'s the cipher on one of the nearby postboxes?',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            (_count - _claimedToday) == 1
                ? 'Look at the postbox and pick the correct royal cipher.'
                : 'Look at one of the postboxes and pick its royal cipher.',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
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
      ),
      ),
    );
  }

  Widget _buildQuizFailed(BuildContext context) {
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
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
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
      ),
    );
  }

  Widget _buildClaimed(BuildContext context) {
    return Stack(
      children: [
        LayoutBuilder(
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
              onPressed: () => setState(() => currentStage = ClaimStage.initial),
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
