// Regression test for the ClaimQuizSheet claim path — specifically the
// fix in commit 5b694d4: `onClaimRecorded` must fire *before* the post-claim
// `if (!mounted) return` guard, so a sheet swiped away during the startScoring
// round-trip still credits the parent's running tally (e.g. LiveRouteScreen's
// route points) for a claim that committed server-side.
//
// This is now testable end-to-end because ClaimQuizSheet exposes a
// `positionProvider` injection seam (alongside the existing nearbyCallable /
// startScoringCallable seams), so the claim path no longer needs the geolocator
// platform channel.

import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/james_strip.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/widgets/claim_quiz_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeResult<T> implements HttpsCallableResult<T> {
  _FakeResult(this.data);
  @override
  final T data;
}

/// Lets a test throw a typed FirebaseFunctionsException with a chosen code +
/// message. The real constructor is `@protected`; a subclass may call it via
/// `super` without tripping the analyzer.
class _FakeFunctionsException extends FirebaseFunctionsException {
  _FakeFunctionsException({required super.code, required super.message});
}

/// Maintenance OFF so MaintenanceGuard.blocked() (called at the top of
/// _claimPostbox) lets the claim proceed. Mirrors the stub in
/// maintenance_guard_test.dart.
class _StubRemoteConfig extends Fake implements FirebaseRemoteConfig {
  @override
  bool getBool(String key) => false;
  @override
  String getString(String key) => '';
  // No remote overrides set: 0.0 is out of the claim-radius safety band, so
  // RemoteConfigService.claimRadiusMeters falls back to its hard-coded default
  // (30 m) — the pre-Remote-Config behaviour.
  @override
  double getDouble(String key) => 0.0;
}

Position _fakePos() => Position(
      latitude: 51.5,
      longitude: -0.12,
      timestamp: DateTime.now(),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

/// One unclaimed postbox whose cipher is NOT a known monarch, so
/// collectValidQuizCiphers returns empty and tapping "Claim" goes straight to
/// _claimPostbox (no quiz UI to navigate).
Future<HttpsCallableResult<dynamic>> _nearbyUnknownCipher(
    Map<String, dynamic> _) async {
  return _FakeResult<dynamic>({
    'counts': {'total': 1, 'claimedToday': 0},
    'points': {'min': 9, 'max': 9},
    'postboxes': {
      'pb1': {
        'distance': 15.0,
        'claimedToday': false,
        'monarch': 'NOT_A_REAL_CIPHER',
      },
    },
    'compass': <String, dynamic>{},
    'claimedCompass': <String, dynamic>{},
  });
}

Position _posAt(double lat, double lng) => Position(
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.now(),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

/// A `nearbyPostboxes` stub that always reports zero postboxes (→ empty stage)
/// and records every call's payload so a test can assert a rescan re-invoked it
/// with the moved-to coordinates.
NearbyPostboxesCallableFn _countingEmptyNearby(List<Map<String, dynamic>> calls) {
  return (payload) async {
    calls.add(payload);
    return _FakeResult<dynamic>(<String, dynamic>{
      'counts': {'total': 0, 'claimedToday': 0},
      'points': {'min': 0, 'max': 0},
      'postboxes': <String, dynamic>{},
      'compass': <String, dynamic>{},
      'claimedCompass': <String, dynamic>{},
    });
  };
}

Future<void> _settle(WidgetTester tester) =>
    tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)))
        .then((_) => tester.pump());

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    SharedPreferences.setMockInitialValues({});
    // The results stage renders a PostboxMap; flutter_map's built-in tile cache
    // calls getApplicationCacheDirectory on path_provider, which has no
    // implementation in the headless test. Stub the channel so the map can
    // build without a MissingPluginException.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => '.',
    );
  });

  setUp(() {
    RemoteConfigService.instance =
        RemoteConfigService(remoteConfig: _StubRemoteConfig());
  });
  tearDown(RemoteConfigService.resetForTest);

  testWidgets(
      'onClaimRecorded fires even when the sheet is dismissed mid-claim',
      (tester) async {
    // startScoring is held in flight via a completer so we can dismiss the
    // sheet while the claim round-trip is pending — exactly the window the
    // 5b694d4 guard covers.
    final gate = Completer<HttpsCallableResult<dynamic>>();
    ClaimQuizResult? recorded;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ClaimQuizSheet(
          scanPosition: const LatLng(51.5, -0.12),
          nearbyCallable: _nearbyUnknownCipher,
          positionProvider: () async => _fakePos(),
          startScoringCallable: (_) => gate.future,
          onClaimRecorded: (r) => recorded = r,
          onCompleted: (_) {},
        ),
      ),
    ));

    // initState's post-frame _runSearch resolves → results stage.
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Claim this postbox!'), findsOneWidget);

    // Tap claim → no valid ciphers → _claimPostbox → positionProvider →
    // startScoring (gated, in flight).
    await tester.tap(find.text('Claim this postbox!'));
    await tester.pump(); // _isClaiming = true; positionProvider awaited
    await _settle(tester); // let positionProvider resolve; claim now gated

    // Sanity: nothing recorded yet (server hasn't responded).
    expect(recorded, isNull);

    // Dismiss the sheet mid-claim by replacing the tree (disposes the State).
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));

    // Server claim commits now, after the sheet is gone.
    gate.complete(_FakeResult<dynamic>(<String, dynamic>{
      'found': true,
      'claimed': 1,
      'points': 9,
      'allClaimedToday': false,
    }));
    await _settle(tester);

    expect(recorded, isNotNull,
        reason: 'onClaimRecorded must fire before the post-claim mounted check '
            'so a mid-claim dismissal still credits the parent tally');
    expect(recorded!.claimedCount, 1);
    expect(recorded!.pointsEarned, 9);
  });

  testWidgets(
      'a failed-precondition claim surfaces the server anti-spoof message',
      (tester) async {
    // startScoring throws `failed-precondition` for the travel-speed anti-spoof
    // check, with a user-facing message. The sheet must show THAT message (so a
    // legitimately fast-moving user is told to slow down) rather than the
    // generic "Could not claim postbox" fallback. Mirrors the Wear coverage in
    // wear_claim_page_test.dart; pins the phone behaviour added in 4d151ad.
    const tooFast = "You're travelling too fast to claim. Slow down, postie.";
    ClaimQuizResult? recorded;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ClaimQuizSheet(
          scanPosition: const LatLng(51.5, -0.12),
          nearbyCallable: _nearbyUnknownCipher,
          positionProvider: () async => _fakePos(),
          startScoringCallable: (_) async => throw _FakeFunctionsException(
            code: 'failed-precondition',
            message: tooFast,
          ),
          onClaimRecorded: (r) => recorded = r,
          onCompleted: (_) {},
        ),
      ),
    ));

    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('Claim this postbox!'));
    await tester.pump(); // _isClaiming = true; positionProvider awaited
    await _settle(tester); // positionProvider + the throwing claim resolve
    await tester.pump(); // surface the SnackBar

    expect(find.text(tooFast), findsOneWidget,
        reason: 'the server anti-spoof message must be shown verbatim');
    expect(find.text('Could not claim postbox. Please try again.'), findsNothing,
        reason: 'the generic fallback must not mask the specific message');
    // A rejected claim records nothing and leaves the user able to retry.
    expect(recorded, isNull);
  });

  testWidgets(
      'empty state offers Rescan only after the user moves past the threshold, '
      'and rescans in place at the moved-to position', (tester) async {
    final calls = <Map<String, dynamic>>[];
    final moves = StreamController<Position>.broadcast();
    addTearDown(moves.close);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ClaimQuizSheet(
          scanPosition: const LatLng(51.5, -0.12),
          nearbyCallable: _countingEmptyNearby(calls),
          positionStreamProvider: () => moves.stream,
          onCompleted: (_) {},
        ),
      ),
    ));

    // initState's post-frame _runSearch resolves → empty stage.
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('No postboxes found within'), findsOneWidget);
    expect(find.text('Rescan from here'), findsNothing,
        reason: 'no movement yet, so the rescan option must be hidden');
    expect(calls, hasLength(1), reason: 'one scan from initState');

    // A sub-threshold move (~5.5 m north) must NOT reveal the button.
    moves.add(_posAt(51.50005, -0.12));
    await _settle(tester);
    expect(find.text('Rescan from here'), findsNothing,
        reason: 'a move under the 10 m threshold should not offer rescan');

    // A move past the 10 m threshold (~22 m north) reveals the button.
    moves.add(_posAt(51.5002, -0.12));
    await _settle(tester);
    expect(find.text('Rescan from here'), findsOneWidget);

    // Tapping it re-runs the scan at the moved-to position (in place).
    await tester.tap(find.text('Rescan from here'));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 50));

    expect(calls, hasLength(2), reason: 'rescan must re-invoke nearbyPostboxes');
    expect((calls.last['lat'] as num).toDouble(), closeTo(51.5002, 1e-6),
        reason: 'rescan must scan the moved-to position, not the original point');
  });

  // ── Route-mode (compact) James ────────────────────────────────────────────
  // In route mode the sheet is a modal over LiveRouteScreen, occluding that
  // screen's own JamesStrip, and there is no Home JamesControllerScope above
  // it. So in compact mode the sheet must own its own controller + render its
  // own strip; otherwise its James lines silently no-op. The normal Claim tab
  // (compact:false) keeps using the Home strip and must render no strip here.

  testWidgets('compact route-mode sheet renders its own JamesStrip',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ClaimQuizSheet(
          scanPosition: const LatLng(51.5, -0.12),
          compact: true,
          nearbyCallable: _nearbyUnknownCipher,
          positionProvider: () async => _fakePos(),
          startScoringCallable: (_) async =>
              _FakeResult<dynamic>(<String, dynamic>{}),
          onCompleted: (_) {},
        ),
      ),
    ));
    await _settle(tester);

    expect(find.byType(JamesStrip), findsOneWidget);
  });

  testWidgets('non-compact sheet renders no JamesStrip (Claim tab uses Home strip)',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ClaimQuizSheet(
          scanPosition: const LatLng(51.5, -0.12),
          nearbyCallable: _nearbyUnknownCipher,
          positionProvider: () async => _fakePos(),
          startScoringCallable: (_) async =>
              _FakeResult<dynamic>(<String, dynamic>{}),
          onCompleted: (_) {},
        ),
      ),
    ));
    await _settle(tester);

    expect(find.byType(JamesStrip), findsNothing);
  });

  testWidgets('compact route-mode claim success drives the sheet\'s own James',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ClaimQuizSheet(
          scanPosition: const LatLng(51.5, -0.12),
          compact: true,
          nearbyCallable: _nearbyUnknownCipher,
          positionProvider: () async => _fakePos(),
          startScoringCallable: (_) async => _FakeResult<dynamic>(
            <String, dynamic>{
              'found': true,
              'claimed': 1,
              'points': 9,
              'allClaimedToday': false,
            },
          ),
          onCompleted: (_) {},
        ),
      ),
    ));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 50));

    // No quiz (unknown cipher) → tapping claim goes straight to _claimPostbox.
    await tester.tap(find.text('Claim this postbox!'));
    await _settle(tester);

    // The success James line must reach the sheet's OWN controller (in route
    // mode JamesController.of(context) is null, so this proves the rewiring).
    final strip = tester.widget<JamesStrip>(find.byType(JamesStrip));
    expect(strip.controller.pendingMessage, isNotNull);
    expect(strip.controller.pendingMessage, isNotEmpty);
  });

  testWidgets('claim sends clientTsMs to startScoring for the anomaly detector',
      (tester) async {
    Map<String, dynamic>? claimPayload;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ClaimQuizSheet(
          scanPosition: const LatLng(51.5, -0.12),
          compact: true,
          nearbyCallable: _nearbyUnknownCipher,
          positionProvider: () async => _fakePos(),
          startScoringCallable: (payload) async {
            claimPayload = payload;
            return _FakeResult<dynamic>(<String, dynamic>{
              'found': true,
              'claimed': 1,
              'points': 9,
              'allClaimedToday': false,
            });
          },
          onCompleted: (_) {},
        ),
      ),
    ));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 50));

    // Unknown cipher → no quiz → claim goes straight to the callable.
    await tester.tap(find.text('Claim this postbox!'));
    await _settle(tester);

    expect(claimPayload, isNotNull);
    expect(claimPayload!['clientTsMs'], isA<int>(),
        reason: 'the claim must carry a client timestamp for the '
            'shadow-mode out-of-window anomaly signal');
  });

  // ── Flaky-link resilience (ROADMAP v1.5, offline play Phase 1) ────────────
  // A network failure used to tear the sheet down (scan) or strand the user
  // behind a SnackBar (claim). Both must now land on a retryable
  // network-error state that preserves the scan/quiz context.

  testWidgets(
      'scan network failure shows Retry instead of cancelling the sheet',
      (tester) async {
    var scanCalls = 0;
    var cancelled = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ClaimQuizSheet(
          scanPosition: const LatLng(51.5, -0.12),
          nearbyCallable: (payload) async {
            scanCalls++;
            // Fail the first burst (initial + auto-retries); succeed after.
            if (scanCalls <= 3) {
              throw _FakeFunctionsException(
                  code: 'unavailable', message: 'transport down');
            }
            return _nearbyUnknownCipher(payload);
          },
          onCancel: () => cancelled = true,
          onCompleted: (_) {},
        ),
      ),
    ));

    // initState scan: first call throws, auto-retries fire on fake timers.
    await _settle(tester);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(cancelled, isFalse,
        reason: 'a transport failure must NOT tear the sheet down');
    expect(find.text('Retry'), findsOneWidget,
        reason: 'the network-error state must offer a Retry');
    expect(scanCalls, 3, reason: 'initial call + 2 automatic retries');

    // Manual retry succeeds and lands on the results stage.
    await tester.tap(find.text('Retry'));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Claim this postbox!'), findsOneWidget);
    expect(cancelled, isFalse);
  });

  testWidgets(
      'claim network failure offers Retry and reuses the same attemptId',
      (tester) async {
    final claimPayloads = <Map<String, dynamic>>[];
    ClaimQuizResult? recorded;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ClaimQuizSheet(
          scanPosition: const LatLng(51.5, -0.12),
          nearbyCallable: _nearbyUnknownCipher,
          positionProvider: () async => _fakePos(),
          startScoringCallable: (payload) async {
            claimPayloads.add(payload);
            if (claimPayloads.length <= 3) {
              throw _FakeFunctionsException(
                  code: 'unavailable', message: 'transport down');
            }
            return _FakeResult<dynamic>(<String, dynamic>{
              'found': true,
              'claimed': 1,
              'points': 9,
              'allClaimedToday': false,
            });
          },
          onClaimRecorded: (r) => recorded = r,
          onCompleted: (_) {},
        ),
      ),
    ));

    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 50));

    // Unknown cipher → no quiz → claim path directly.
    await tester.tap(find.text('Claim this postbox!'));
    await _settle(tester); // position + first claim call
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(find.text('Retry'), findsOneWidget,
        reason: 'a transport failure on claim must offer a Retry, '
            'not strand the user behind a SnackBar');
    expect(claimPayloads, hasLength(3),
        reason: 'initial claim + 2 automatic retries');
    final ids = claimPayloads.map((p) => p['attemptId']).toSet();
    expect(ids, hasLength(1),
        reason: 'automatic retries must reuse the SAME attemptId so the '
            'server can replay the stored response');
    expect(ids.first, isA<String>());
    expect((ids.first as String).isNotEmpty, isTrue);

    // Manual retry: still the same attemptId; now the claim succeeds.
    await tester.tap(find.text('Retry'));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 50));

    expect(claimPayloads, hasLength(4));
    expect(claimPayloads.last['attemptId'], ids.first,
        reason: 'the manual Retry must keep the original attemptId — a new '
            'id would defeat the idempotent replay');
    expect(recorded, isNotNull);
    expect(recorded!.pointsEarned, 9);
  });

  testWidgets('claim payload carries a fresh attemptId string', (tester) async {
    Map<String, dynamic>? claimPayload;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ClaimQuizSheet(
          scanPosition: const LatLng(51.5, -0.12),
          compact: true,
          nearbyCallable: _nearbyUnknownCipher,
          positionProvider: () async => _fakePos(),
          startScoringCallable: (payload) async {
            claimPayload = payload;
            return _FakeResult<dynamic>(<String, dynamic>{
              'found': true,
              'claimed': 1,
              'points': 9,
              'allClaimedToday': false,
            });
          },
          onCompleted: (_) {},
        ),
      ),
    ));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('Claim this postbox!'));
    await _settle(tester);

    expect(claimPayload, isNotNull);
    expect(claimPayload!['attemptId'], isA<String>());
    expect((claimPayload!['attemptId'] as String).length,
        greaterThanOrEqualTo(16),
        reason: 'attemptId must be long enough to be collision-safe');
  });
}
