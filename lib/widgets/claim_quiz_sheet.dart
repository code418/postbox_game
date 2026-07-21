import 'dart:async';
import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:postbox_game/firebase_functions_eu.dart';
import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/app_preferences.dart';
import 'package:postbox_game/services/user_properties_publisher.dart';
import 'package:postbox_game/james_controller.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/james_strip.dart';
import 'package:postbox_game/location_service.dart';
import 'package:postbox_game/maintenance_guard.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/reports/report_missing_postbox_screen.dart';
import 'package:postbox_game/services/claim_outbox.dart';
import 'package:postbox_game/services/crashlytics_helper.dart';
import 'package:postbox_game/services/device_id_service.dart';
import 'package:postbox_game/services/home_widget_service.dart';
import 'package:postbox_game/services/scan_cache.dart';
import 'package:postbox_game/services/perf_service.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/widgets/postbox_map.dart';
import 'package:postbox_game/widgets/postbox_marker.dart';
import 'package:postbox_game/widgets/quiz_helpers.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Callable typedefs (injectable for testing)
// ─────────────────────────────────────────────────────────────────────────────

/// Matches the signature of [HttpsCallable.call] for the `nearbyPostboxes`
/// function. Tests can inject a stub without subclassing the sealed
/// [HttpsCallable].
typedef NearbyPostboxesCallableFn = Future<HttpsCallableResult<dynamic>>
    Function(Map<String, dynamic>);

/// Matches the signature of [HttpsCallable.call] for the `startScoring`
/// function. Tests can inject a stub without subclassing the sealed
/// [HttpsCallable].
typedef StartScoringCallableFn = Future<HttpsCallableResult<dynamic>> Function(
    Map<String, dynamic>);

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

enum _QuizStage {
  searching,
  results,
  empty,
  quiz,
  quizFailed,
  claimed,
  /// A transport failure (offline / server unreachable) interrupted the scan
  /// or the claim. Preserves all scan/quiz state and offers a Retry — tearing
  /// the sheet down here is how players used to lose earned claims
  /// (ROADMAP v1.5, offline play Phase 1).
  networkError,
  /// The claim was captured to the offline outbox (Phase 3 warm path); it
  /// settles via flushOfflineClaims when the link returns.
  banked,
}

/// How far (metres) the user must move from the scan point before the empty
/// state offers a "Rescan from here" button. Far enough that a rescan can
/// plausibly bring new postboxes into the claim radius, while ignoring GPS
/// jitter.
const double _emptyRescanMoveThresholdM = 10.0;

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
    this.nearbyCallable,
    this.startScoringCallable,
    this.onClaimRecorded,
    this.positionProvider,
    this.positionStreamProvider,
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

  /// Optional callback fired as soon as the server-side claim transaction
  /// commits, regardless of whether the user later taps "Keep exploring" or
  /// dismisses the sheet (e.g. swipes the modal down). Parents that show a
  /// running total (LiveRouteScreen) wire this so the totals update even on
  /// dismiss-after-claim; the existing [onCompleted] only fires from the
  /// explicit button path, so without this callback a dismiss would lose
  /// the server-credited claim from the parent's local tally.
  final ValueChanged<ClaimQuizResult>? onClaimRecorded;

  /// Optional streak stream supplied by the parent. When non-null the claimed
  /// screen shows a streak chip driven by this stream. Pass the parent's own
  /// cached stream so there is only one [StreakService] subscription at a time.
  /// When null the streak chip is omitted from [_buildClaimed].
  final Stream<int?>? streakStream;

  /// Injectable stub for the `nearbyPostboxes` Firebase callable.
  /// When null, defaults to [appFunctions.httpsCallable].
  /// Inject in tests to avoid real Firebase initialisation.
  final NearbyPostboxesCallableFn? nearbyCallable;

  /// Injectable stub for the `startScoring` Firebase callable.
  /// When null, defaults to [appFunctions.httpsCallable].
  /// Inject in tests to avoid real Firebase initialisation.
  final StartScoringCallableFn? startScoringCallable;

  /// Injectable provider for the live GPS fix taken at claim time. When null,
  /// defaults to [getPosition] from location_service. Inject in tests to drive
  /// the full claim path without the geolocator platform channel (which throws
  /// MissingPluginException headless), matching the other seams above.
  final Future<Position> Function()? positionProvider;

  /// Injectable provider for the live GPS stream used by the empty state to
  /// detect when the user has walked far enough that a rescan could surface new
  /// postboxes. When null, defaults to [positionStream] from location_service.
  /// Inject in tests to drive movement without the geolocator platform channel,
  /// matching the other seams above.
  final Stream<Position> Function()? positionStreamProvider;

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
  // Distinct known ciphers on nearby unclaimed-today postboxes — any one is a
  // correct answer. The UI prompts the user to look at "one of the nearby
  // postboxes" when there are multiple, so locking the answer to a single
  // randomly-picked cipher would reject correct identifications of other
  // postboxes the user might have looked at.
  Set<String> _validQuizCiphers = const {};

  // ── Claim result ─────────────────────────────────────────────────────────
  int _pointsEarned = 0;
  int _claimedCount = 0;
  bool _isClaiming = false;

  // ── Network-error retry state ─────────────────────────────────────────────
  // Identifies the current logical claim attempt for the server's idempotent
  // replay (functions/src/_attempts.ts). Generated when a claim attempt
  // starts, KEPT across transport-failure retries (same id → the server
  // replays the stored response instead of hitting the already-claimed
  // fast-path with zero points), and cleared on any definitive outcome.
  String? _attemptId;
  // Whether the Retry button on the networkError stage re-runs the claim
  // (true) or the scan (false).
  bool _retryIsClaim = false;

  // ── Offline capture state (v1.5 Phase 3) ──────────────────────────────────
  // The HMAC capture token issued with the current scan (live or cached).
  String? _scanId;
  // True when the results on screen came from ScanCache (the offline rescue):
  // claims then bank straight to the outbox instead of calling the server.
  bool _offlineFromCache = false;
  // The GPS fix acquired by the most recent _claimPostbox — the position an
  // offline capture is banked with.
  Position? _lastClaimPosition;

  // ── State machine ─────────────────────────────────────────────────────────
  _QuizStage _stage = _QuizStage.searching;

  // ── Scan centre / empty-state movement watch ───────────────────────────────
  // The position the current scan is centred on. Initialised to
  // widget.scanPosition and updated by each _runSearch so the radius map and
  // the movement check track the spot we actually scanned (not the now-stale
  // position from when the sheet was first opened).
  late LatLng _scanCenter;
  StreamSubscription<Position>? _moveSub;
  // True once the user has walked ≥ _emptyRescanMoveThresholdM from _scanCenter
  // while on the empty state; gates the "Rescan from here" button.
  bool _movedSinceScan = false;
  // The most recent fix from the movement watch, used as the rescan target.
  LatLng? _latestFix;

  // ── Animations ────────────────────────────────────────────────────────────
  late AnimationController _successController;
  late Animation<double> _successScale;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;
  late ConfettiController _confettiController;

  // ── Services ──────────────────────────────────────────────────────────────
  late final NearbyPostboxesCallableFn _nearbyCallable;
  late final StartScoringCallableFn _claimCallable;
  late final Future<Position> Function() _positionProvider;
  late final Stream<Position> Function() _positionStreamProvider;
  final HomeWidgetService _homeWidgetService = HomeWidgetService();

  /// In compact (route-modal) mode the sheet is shown over LiveRouteScreen,
  /// occluding that screen's JamesStrip, with no Home JamesControllerScope
  /// above it. So it owns its own controller and renders its own strip (see
  /// [build]). Null in the inline Claim-tab mode, which uses the Home strip.
  JamesController? _ownJames;

  /// The James controller to drive: the sheet's own (compact/route mode) or
  /// the Home shell's inherited one (inline Claim-tab mode, where _ownJames is
  /// null and the JamesControllerScope is an ancestor).
  JamesController? get _james => _ownJames ?? JamesController.of(context);

  @override
  void initState() {
    super.initState();

    _scanCenter = widget.scanPosition;
    _ownJames = widget.compact ? JamesController() : null;
    _positionStreamProvider =
        widget.positionStreamProvider ?? (() => positionStream());
    _nearbyCallable = widget.nearbyCallable ??
        (payload) => appFunctions
            .httpsCallable('nearbyPostboxes')
            .call(payload);
    _claimCallable = widget.startScoringCallable ??
        (payload) => appFunctions
            .httpsCallable('startScoring')
            .call(payload);
    _positionProvider = widget.positionProvider ?? getPosition;

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
    unawaited(_moveSub?.cancel());
    _successController.dispose();
    _pulseController.dispose();
    _confettiController.dispose();
    _ownJames?.dispose();
    super.dispose();
  }

  // ── Empty-state movement watch ──────────────────────────────────────────────

  /// Watches the user's position while on the empty state. Once they have moved
  /// at least [_emptyRescanMoveThresholdM] from [_scanCenter], reveals the
  /// "Rescan from here" button (a rescan from the same spot would just repeat
  /// the empty result, so we only offer it once a rescan could find something).
  ///
  /// Skipped in compact/route mode, where the route screen already tracks
  /// movement and the empty sheet is transient.
  void _startMoveWatch() {
    if (widget.compact) return;
    _stopMoveWatch();
    _moveSub = _positionStreamProvider().listen(
      (pos) {
        if (!mounted || _stage != _QuizStage.empty) return;
        final movedM = Geolocator.distanceBetween(
          _scanCenter.latitude,
          _scanCenter.longitude,
          pos.latitude,
          pos.longitude,
        );
        if (movedM >= _emptyRescanMoveThresholdM) {
          setState(() {
            _latestFix = LatLng(pos.latitude, pos.longitude);
            _movedSinceScan = true;
          });
        }
      },
      // Passive enhancement: permission is already held (the scan succeeded),
      // so a stream error just means we leave the button hidden — no SnackBar.
      onError: (_) => _stopMoveWatch(),
    );
  }

  void _stopMoveWatch() {
    unawaited(_moveSub?.cancel());
    _moveSub = null;
  }

  // ── Search ────────────────────────────────────────────────────────────────

  /// Applies a parsed nearbyPostboxes payload (live or cached) to the sheet
  /// state and advances to results/empty.
  void _applyScanData(Map<String, dynamic> data,
      {required String? scanId, required bool fromCache}) {
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
      _scanId = scanId;
      _offlineFromCache = fromCache;
      _stage = _count > 0 ? _QuizStage.results : _QuizStage.empty;
    });
  }

  /// Offline rescue (v1.5 Phase 3): when a scan can't reach the server, serve
  /// the last successful scan IF it's fresh and taken from (nearly) the same
  /// spot. Returns true when the rescue applied.
  bool _tryOfflineScanRescue(LatLng scanPos) {
    final cached = ScanCache.fresh();
    if (cached == null) return false;
    final movedM = Geolocator.distanceBetween(
      cached.position.latitude,
      cached.position.longitude,
      scanPos.latitude,
      scanPos.longitude,
    );
    // Matches the server's flush-time proximity bound (MAX_SCAN_DISTANCE_M):
    // beyond it the flush would reject the capture anyway.
    if (movedM > 250) return false;
    _applyScanData(Map<String, dynamic>.from(cached.data),
        scanId: cached.scanId, fromCache: true);
    _james?.show(JamesMessages.offlineFromLastScan.resolve());
    return true;
  }

  /// Scans for postboxes around [position] (default = the original
  /// `widget.scanPosition`).
  ///
  /// The post-claim retry paths pass the current GPS so the rescan reflects
  /// where the user actually is now, not where they were when they first
  /// tapped Scan — otherwise an "out of range" claim followed by an auto-
  /// rescan would still show the now-distant postbox as "in range".
  Future<void> _runSearch({LatLng? position}) async {
    final scanPos = position ?? widget.scanPosition;
    // A new scan supersedes any prior empty-state movement watch and recentres
    // the radius map / movement check on the spot we're about to scan.
    _stopMoveWatch();
    _scanCenter = scanPos;
    _movedSinceScan = false;
    _latestFix = null;
    if (_stage != _QuizStage.searching) {
      setState(() => _stage = _QuizStage.searching);
    }

    Analytics.scanStarted();

    try {
      _distanceUnit = await AppPreferences.getDistanceUnit();

      // Scans are read-only, so wholesale retry on transport failure is safe.
      final result = await retryOnUnavailable(() => _nearbyCallable(<String, dynamic>{
            'lat': scanPos.latitude,
            'lng': scanPos.longitude,
            'meters': RemoteConfigService.instance.claimRadiusMeters,
          }));

      if (!mounted) return;

      final data = Map<String, dynamic>.from(result.data as Map);
      // Cache the scan for the offline rescue path. The payload carries no
      // coordinates (applyUserClaims strips them server-side) and the scanId
      // is the server-issued offline capture token.
      final freshScanId = data['scanId'] as String?;
      if (freshScanId != null) {
        ScanCache.store(CachedScan(
          data: data,
          scanId: freshScanId,
          position: scanPos,
          fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
        ));
      }
      _applyScanData(data, scanId: freshScanId, fromCache: false);

      if (_count > 0) {
        Analytics.scanComplete(
          count: _count,
          claimedToday: _claimedToday,
          minPoints: _minPoints,
          maxPoints: _maxPoints,
        );
        if (mounted && _claimedToday == _count) {
          _james
              ?.show(JamesMessages.claimErrorAlreadyClaimed.resolve());
        }
      } else {
        Analytics.scanEmpty();
        // Start watching for movement so we can offer an in-place rescan once
        // the user has walked far enough that a new scan could find something.
        _startMoveWatch();
        if (mounted) {
          _james
              ?.show(JamesMessages.claimScanEmpty.resolve());
        }
      }
    } on FirebaseFunctionsException catch (e) {
      debugPrint('Firebase functions error: ${e.code} ${e.message}');
      final isTransport = retryableCallableCodes.contains(e.code);
      CrashlyticsHelper.recordHandled(e, e.stackTrace,
          reason: 'nearbyPostboxes:${e.code}',
          dedupeKey: isTransport ? 'nearbyPostboxes_unavailable' : null);
      if (!mounted) return;
      if (isTransport) {
        // Offline rescue first: a fresh cached scan from this spot serves the
        // results and routes the claim to the outbox (v1.5 Phase 3).
        if (_tryOfflineScanRescue(scanPos)) return;
        // Transport failure (offline / unreachable): keep the sheet alive on
        // the retryable network-error stage — the automatic retries in
        // retryOnUnavailable are already exhausted by the time we get here.
        _james?.show(JamesMessages.errorOffline.resolve());
        setState(() {
          _retryIsClaim = false;
          _stage = _QuizStage.networkError;
        });
        return;
      }
      _showErrorSnackBar('Could not scan for postboxes. Please try again.');
      _james?.show(JamesMessages.claimErrorGeneral.resolve());
      _cancel();
    } on TimeoutException {
      if (!mounted) return;
      // A timed-out round-trip is a transport failure too: same rescue, same
      // retry state.
      if (_tryOfflineScanRescue(scanPos)) return;
      _james?.show(JamesMessages.errorOffline.resolve());
      setState(() {
        _retryIsClaim = false;
        _stage = _QuizStage.networkError;
      });
      return;
    } on LocationServiceException catch (e) {
      debugPrint('Location error scanning: $e');
      switch (e.kind) {
        case LocationErrorKind.permissionPermanentlyDenied:
          unawaited(Analytics.locationPermissionPermanentlyDenied());
          _showPermissionDeniedSnackBar();
        case LocationErrorKind.servicesDisabled:
          _showLocationServicesDisabledSnackBar();
        case LocationErrorKind.permissionDenied:
          _showErrorSnackBar(e.message);
      }
      if (!mounted) return;
      final isPermission =
          e.kind == LocationErrorKind.permissionDenied ||
              e.kind == LocationErrorKind.permissionPermanentlyDenied;
      _james?.show(isPermission
          ? JamesMessages.nearbyErrorPermission.resolve()
          : JamesMessages.claimErrorGeneral.resolve());
      _cancel();
    } catch (e) {
      debugPrint('Error scanning: $e');
      _showErrorSnackBar('Could not scan for postboxes. Please try again.');
      if (!mounted) return;
      _james
          ?.show(JamesMessages.claimErrorGeneral.resolve());
      _cancel();
    } finally {
      // Safety net: ensure we never get permanently stuck in 'searching' state.
      if (mounted && _stage == _QuizStage.searching) {
        _cancel();
      }
    }
  }

  // ── Claim ─────────────────────────────────────────────────────────────────

  /// Generates a collision-safe id for one logical claim attempt (32 hex
  /// chars). Kept across retries; the server replays the stored response for
  /// a repeated id (functions/src/_attempts.ts).
  static String _generateAttemptId() {
    final rnd = Random.secure();
    return List<int>.generate(16, (_) => rnd.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<void> _claimPostbox({bool isRetry = false}) async {
    if (_isClaiming) return;
    if (MaintenanceGuard.blocked(context, actionLabel: 'claim')) {
      return;
    }
    // A fresh attempt gets a fresh id; a Retry after a transport failure MUST
    // keep the old one so the server can replay the stored response instead
    // of falling into the already-claimed fast-path with zero points.
    if (!isRetry || _attemptId == null) _attemptId = _generateAttemptId();
    final attemptId = _attemptId!;
    setState(() => _isClaiming = true);
    HapticFeedback.mediumImpact();
    try {
      final position = await _positionProvider();
      _lastClaimPosition = position;

      // Offline mode (v1.5 Phase 3): the results came from the scan cache, so
      // the server is unreachable — bank the capture instead of calling it.
      if (_offlineFromCache) {
        await _bankCapture(position, attemptId);
        return;
      }
      // Stable per-install id for the shadow-mode repeated-device signal. Null
      // (best-effort) when unavailable — the key is then omitted so the server
      // never sees a null deviceIdHash.
      final deviceIdHash = await DeviceIdService.get();
      final result = await PerfService.traceAsync(
        PerfTraces.callableStartScoring,
        (trace) async {
          try {
            // Safe to auto-retry ONLY because attemptId makes the call
            // idempotent server-side (see _attempts.ts).
            final r = await retryOnUnavailable(() => _claimCallable(<String, dynamic>{
                  'lat': position.latitude,
                  'lng': position.longitude,
                  // Client wall-clock for the shadow-mode out-of-window anomaly
                  // signal (server compares it against its own claim timestamp).
                  'clientTsMs': DateTime.now().millisecondsSinceEpoch,
                  if (deviceIdHash != null) 'deviceIdHash': deviceIdHash,
                  'attemptId': attemptId,
                }));
            trace.putAttribute(PerfTraces.attrOutcome, 'ok');
            return r;
          } catch (_) {
            trace.putAttribute(PerfTraces.attrOutcome, 'error');
            rethrow;
          }
        },
        attributes: {PerfTraces.attrMonarch: _quizCipher ?? 'unknown'},
      );
      // The server answered: this logical attempt is settled either way.
      _attemptId = null;
      final claimData = Map<String, dynamic>.from(result.data as Map);
      final found = claimData['found'] == true;
      final allClaimedToday = claimData['allClaimedToday'] == true;
      final rawClaimed = claimData['claimed'] ?? 0;
      final claimedCount =
          rawClaimed is int ? rawClaimed : (rawClaimed as num).toInt();

      // Use the fresh GPS we just acquired for the post-claim rescan, so an
      // out-of-range or already-claimed retry sees the user's current
      // position — not the now-stale position from when they first tapped
      // Scan. Without this, a user who walked away from the original scan
      // point would keep seeing the same postbox listed as "in range".
      final freshPos = LatLng(position.latitude, position.longitude);

      if (!found) {
        Analytics.claimFailed(reason: 'out_of_range');
        if (!mounted) return;
        setState(() => _isClaiming = false);
        _james
            ?.show(JamesMessages.claimOutOfRange.resolve());
        await _runSearch(position: freshPos);
        return;
      }
      if (allClaimedToday || claimedCount == 0) {
        Analytics.claimFailed(reason: 'already_claimed_today');
        if (!mounted) return;
        setState(() => _isClaiming = false);
        _showErrorSnackBar('Already claimed today — come back tomorrow!');
        _james
            ?.show(JamesMessages.claimErrorAlreadyClaimed.resolve());
        await _runSearch(position: freshPos);
        return;
      }
      final points = claimData['points'] ?? 0;
      final earnedPts = points is int ? points : (points as num).toInt();
      // The server claim has committed. Notify the parent's running tally
      // (e.g. LiveRouteScreen) BEFORE the local mounted check: if the user
      // swiped this modal away during the claim round-trip, the sheet is
      // unmounted but the claim is real, so the route total must still be
      // credited. The parent guards its own mounted state; onCompleted (the
      // explicit-button path) is unaffected.
      widget.onClaimRecorded?.call(ClaimQuizResult(
        claimedCount: claimedCount,
        pointsEarned: earnedPts,
      ));
      if (!mounted) return;
      Analytics.claimSuccess(
          pointsEarned: earnedPts, claimedCount: claimedCount);
      // Crash context: which cypher the user just claimed (code only, no PII).
      CrashlyticsHelper.setContext(
          CrashlyticsHelper.keyLastMonarch, _quizCipher ?? 'unknown');
      // Refresh the bucketed user properties (lifetime points, unique boxes,
      // streak, claimed_today) so Remote Config audiences see the new state.
      // Fire-and-forget — analytics never blocks the UI.
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        unawaited(publishUserPropertiesFromFirestore(uid));
      }
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
        _james?.show(msg);
      }
    } on FirebaseFunctionsException catch (e) {
      debugPrint('Claim error: ${e.code} ${e.message}');
      Analytics.claimFailed(reason: e.code);
      // 'failed-precondition' is the expected anti-spoof "too fast" rejection —
      // user-driven, not a bug, so don't record it as a non-fatal.
      if (e.code != 'failed-precondition') {
        CrashlyticsHelper.recordHandled(e, e.stackTrace,
            reason: 'startScoring:${e.code}',
            dedupeKey: retryableCallableCodes.contains(e.code)
                ? 'startScoring_unavailable'
                : null);
      }
      if (!mounted) return;
      if (retryableCallableCodes.contains(e.code)) {
        // Transport failure: the automatic retries are exhausted. Keep the
        // quiz context AND the attemptId, and offer a manual Retry — the
        // claim may have committed server-side, and the replay mechanism
        // will surface the real outcome when the link recovers.
        _james?.show(JamesMessages.errorOffline.resolve());
        setState(() {
          _isClaiming = false;
          _retryIsClaim = true;
          _stage = _QuizStage.networkError;
        });
        return;
      }
      // A definitive server answer settles this logical attempt.
      _attemptId = null;
      // The server's anti-spoof travel-speed check throws `failed-precondition`
      // with a message written for the end user ("You're travelling too
      // fast..."). Surface that instead of the generic "try again" so a user
      // who's moving too quickly is told to slow down, not to retry futilely.
      final String snackMsg;
      final String jamesMsg;
      switch (e.code) {
        case 'failed-precondition':
          snackMsg = (e.message != null && e.message!.isNotEmpty)
              ? e.message!
              : "You're travelling too fast to claim. Slow down and try again.";
          jamesMsg = JamesMessages.claimErrorTooFast.resolve();
        default:
          snackMsg = 'Could not claim postbox. Please try again.';
          jamesMsg = JamesMessages.claimErrorGeneral.resolve();
      }
      _showErrorSnackBar(snackMsg);
      setState(() => _isClaiming = false);
      _james?.show(jamesMsg);
    } on LocationServiceException catch (e) {
      debugPrint('Location error claiming: $e');
      final isPermission =
          e.kind == LocationErrorKind.permissionDenied ||
              e.kind == LocationErrorKind.permissionPermanentlyDenied;
      switch (e.kind) {
        case LocationErrorKind.permissionPermanentlyDenied:
          unawaited(Analytics.locationPermissionPermanentlyDenied());
          _showPermissionDeniedSnackBar();
        case LocationErrorKind.servicesDisabled:
          _showLocationServicesDisabledSnackBar();
        case LocationErrorKind.permissionDenied:
          _showErrorSnackBar(e.message);
      }
      if (!mounted) return;
      setState(() => _isClaiming = false);
      _james?.show(isPermission
          ? JamesMessages.nearbyErrorPermission.resolve()
          : JamesMessages.claimErrorGeneral.resolve());
    } catch (e) {
      debugPrint('Claim error: $e');
      _showErrorSnackBar('Could not claim postbox. Please try again.');
      if (!mounted) return;
      setState(() => _isClaiming = false);
      _james
          ?.show(JamesMessages.claimErrorGeneral.resolve());
    } finally {
      if (mounted && _isClaiming) setState(() => _isClaiming = false);
    }
  }

  // ── Offline banking (v1.5 Phase 3) ────────────────────────────────────────

  /// Bank the current claim to the offline outbox under the active scan
  /// token and show the banked stage. The capture settles (or is honestly
  /// rejected) via flushOfflineClaims when the link returns.
  Future<void> _bankCapture(Position position, String attemptId) async {
    final scanId = _scanId;
    if (scanId == null) return; // no token: banking is not available
    await ClaimOutbox.instance.add(OutboxEntry(
      scanId: scanId,
      lat: position.latitude,
      lng: position.longitude,
      capturedWallMs: DateTime.now().millisecondsSinceEpoch,
      capturedMonotonicMs: ClaimOutbox.monotonicNowMs(),
      attemptId: attemptId,
    ));
    Analytics.claimFailed(reason: 'banked_offline');
    if (!mounted) return;
    setState(() {
      _isClaiming = false;
      _attemptId = null;
      _stage = _QuizStage.banked;
    });
    _james?.show(JamesMessages.offlineBanked.resolve());
  }

  // ── Quiz helpers ──────────────────────────────────────────────────────────

  void _startQuiz() {
    final valid = collectValidQuizCiphers(_postboxes.values);
    if (valid.isEmpty) {
      unawaited(_claimPostbox());
      return;
    }
    final picked = (valid.toList()..shuffle()).first;
    Analytics.quizStarted(cipher: picked);
    setState(() {
      _quizCipher = picked;
      _validQuizCiphers = valid;
      _quizOptions = buildQuizOptions(valid, maxOptions: 4);
      _selectedAnswer = null;
      _stage = _QuizStage.quiz;
    });
  }

  void _onQuizAnswer(String answer) {
    setState(() => _selectedAnswer = answer);
    if (_validQuizCiphers.contains(answer)) {
      Analytics.quizCorrect(cipher: answer);
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
        _james?.show(JamesMessages.quizFailed.resolve());
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

  Widget _claimRadiusMap(
      {bool scanning = false, bool success = false, double height = 180}) {
    final center = _scanCenter;
    if (scanning) {
      return AnimatedBuilder(
        animation: _pulseAnim,
        builder: (_, __) {
          final alpha = 0.35 + _pulseAnim.value * 0.45;
          final strokeWidth = 2.0 + _pulseAnim.value * 3.0;
          return Card(
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              height: height,
              child: PostboxMap(
                center: center,
                zoom: 17,
                interactionOptions:
                    const InteractionOptions(flags: InteractiveFlag.none),
                circleMarkers: [
                  CircleMarker(
                    point: center,
                    radius: RemoteConfigService.instance.claimRadiusMeters,
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
        height: height,
        child: PostboxMap(
          center: center,
          zoom: 17,
          interactionOptions:
              const InteractionOptions(flags: InteractiveFlag.none),
          circleMarkers: [
            CircleMarker(
              point: center,
              radius: RemoteConfigService.instance.claimRadiusMeters,
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
    final content = switch (_stage) {
      _QuizStage.searching => _buildSearching(context),
      _QuizStage.results => _buildResults(context),
      _QuizStage.empty => _buildEmpty(context),
      _QuizStage.quiz => _buildQuiz(context),
      _QuizStage.quizFailed => _buildQuizFailed(context),
      _QuizStage.claimed => _buildClaimed(context),
      _QuizStage.networkError => _buildNetworkError(context),
      _QuizStage.banked => _buildBanked(context),
    };
    final james = _ownJames;
    if (james == null) return content;
    // Route-mode (compact) modal occludes the LiveRouteScreen's own James
    // strip, so render James inside the sheet — pinned to the bottom in the
    // reserved compact band (_bottomPad). Idle, it's slid off-screen and
    // consumes no visible space.
    return Stack(
      children: [
        content,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: JamesStrip(controller: james),
        ),
      ],
    );
  }

  // ── Stage builders ────────────────────────────────────────────────────────

  Widget _buildSearching(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Landscape leaves only a few hundred logical pixels of height, where
        // the fixed 180px map + spinner overflow a non-scrolling column. Lay the
        // map beside the spinner and let it scroll if needed; portrait keeps the
        // original stacked column.
        final landscape = constraints.maxWidth > constraints.maxHeight;
        final progress = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: postalRed),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Scanning within ${AppPreferences.formatShortDistance(RemoteConfigService.instance.claimRadiusMeters, _distanceUnit)}...',
              textAlign: TextAlign.center,
            ),
          ],
        );

        if (landscape) {
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.lg, AppSpacing.md, _bottomPad),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: _claimRadiusMap(scanning: true, height: 140)),
                const SizedBox(width: AppSpacing.lg),
                progress,
              ],
            ),
          );
        }

        return Padding(
          padding: EdgeInsets.fromLTRB(
              AppSpacing.md, AppSpacing.lg, AppSpacing.md, _bottomPad),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _claimRadiusMap(scanning: true),
              const SizedBox(height: AppSpacing.md),
              progress,
            ],
          ),
        );
      },
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
          constraints:
              BoxConstraints(minHeight: constraints.maxHeight - _bottomPad),
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
                'No postboxes found within ${AppPreferences.formatShortDistance(RemoteConfigService.instance.claimRadiusMeters, _distanceUnit)}',
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
              if (_movedSinceScan) ...[
                const SizedBox(height: AppSpacing.xl),
                FilledButton.icon(
                  onPressed: () =>
                      unawaited(_runSearch(position: _latestFix ?? _scanCenter)),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Rescan from here'),
                  style: FilledButton.styleFrom(
                    minimumSize: Size(double.infinity, _buttonHeight),
                  ),
                ),
              ],
              if (!RemoteConfigService.instance.killSwitchReporting) ...[
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
              ],
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
              child: _claimRadiusMap(success: _claimedToday < _count),
            ),
            _summaryCard(context),
            const SizedBox(height: AppSpacing.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
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
                            : '$_count postbox${_count == 1 ? '' : 'es'} within ${AppPreferences.formatShortDistance(RemoteConfigService.instance.claimRadiusMeters, _distanceUnit)}',
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
                      onPressed: _isClaiming ? null : () => _onQuizAnswer(code),
                      style: OutlinedButton.styleFrom(
                        minimumSize: Size(double.infinity, _optionHeight),
                        side: BorderSide(
                          color: isCorrectSelected
                              ? _success(context)
                              : (Theme.of(context).brightness == Brightness.dark
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

  Widget _buildNetworkError(BuildContext context) {
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
              Icon(Icons.wifi_off_rounded, size: 80, color: _warning(context)),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'No connection',
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                _retryIsClaim
                    ? "Couldn't reach the post office to log your claim. "
                        'Your quiz answer is safe — retry when the signal returns.'
                    : "Couldn't reach the post office to scan for postboxes. "
                        'Retry when the signal returns.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xl),
              FilledButton.icon(
                onPressed: () {
                  if (_retryIsClaim) {
                    unawaited(_claimPostbox(isRetry: true));
                  } else {
                    unawaited(_runSearch(position: _scanCenter));
                  }
                },
                style: FilledButton.styleFrom(
                  minimumSize: Size(double.infinity, _buttonHeight),
                ),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
              // Offline banking (v1.5 Phase 3): a claim that already passed
              // the quiz and holds a scan token can be saved to the outbox
              // instead of retried live.
              if (_retryIsClaim && _scanId != null && _lastClaimPosition != null) ...[
                const SizedBox(height: AppSpacing.sm),
                OutlinedButton.icon(
                  onPressed: _isClaiming
                      ? null
                      : () {
                          final attemptId =
                              _attemptId ?? _generateAttemptId();
                          unawaited(
                              _bankCapture(_lastClaimPosition!, attemptId));
                        },
                  style: OutlinedButton.styleFrom(
                    minimumSize: Size(double.infinity, _buttonHeight),
                  ),
                  icon: const Icon(Icons.schedule_send_outlined),
                  label: const Text('Save & post later'),
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: _cancel,
                child: const Text('Back'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBanked(BuildContext context) {
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
              Icon(Icons.schedule_send_outlined,
                  size: 80, color: _warning(context)),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Saved for later',
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                "No signal, so this claim is banked on your phone. "
                "We'll post it automatically when you're back online "
                'and your points will land then.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xl),
              FilledButton.icon(
                onPressed: () =>
                    widget.onCompleted(const ClaimQuizResult()),
                style: FilledButton.styleFrom(
                  minimumSize: Size(double.infinity, _buttonHeight),
                ),
                icon: const Icon(Icons.explore_outlined),
                label: const Text('Keep exploring'),
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
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            color: postalGold, fontWeight: FontWeight.bold),
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
