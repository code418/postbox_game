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
}
