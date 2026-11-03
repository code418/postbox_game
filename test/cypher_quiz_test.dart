// Drives the cypher quiz itself, on the phone (ClaimQuizSheet) and the watch
// (WearClaimView). The other claim-sheet tests stub an unknown cypher so the
// quiz is skipped; these stub one EIIR box so it is shown.

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
import 'package:postbox_game/cypher_guide_screen.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/wear/wear_claim_page.dart';
import 'package:postbox_game/widgets/claim_quiz_sheet.dart';
import 'package:postbox_game/widgets/cypher_art.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeResult<T> implements HttpsCallableResult<T> {
  _FakeResult(this.data);
  @override
  final T data;
}

/// Maintenance off, no Remote Config overrides.
class _StubRemoteConfig extends Fake implements FirebaseRemoteConfig {
  @override
  bool getBool(String key) => false;
  @override
  String getString(String key) => '';
  @override
  double getDouble(String key) => 0.0;
  @override
  int getInt(String key) => 0;
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

/// One unclaimed Elizabeth II box: the quiz has exactly one right answer.
Future<HttpsCallableResult<dynamic>> _nearbyEiir(Map<String, dynamic> _) async {
  return _FakeResult<dynamic>({
    'counts': {'total': 1, 'claimedToday': 0},
    'points': {'min': 2, 'max': 2},
    'postboxes': {
      'pb1': {'distance': 15.0, 'claimedToday': false, 'monarch': 'EIIR'},
    },
    'compass': <String, dynamic>{},
    'claimedCompass': <String, dynamic>{},
  });
}

Future<void> _settle(WidgetTester tester) => tester
    .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)))
    .then((_) => tester.pump());

/// The quiz tile showing [code].
Finder _tile(String code) => find.ancestor(
      of: find.byWidgetPredicate((w) => w is CypherPlate && w.code == code),
      matching: find.byType(OutlinedButton),
    );

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    SharedPreferences.setMockInitialValues({});
    // The results stage renders a PostboxMap, whose tile cache asks
    // path_provider for a directory.
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

  group('phone quiz', () {
    /// Pumps the sheet on a phone-sized screen and opens the quiz. Returns
    /// the startScoring calls.
    Future<List<Map<String, dynamic>>> openQuiz(
      WidgetTester tester, {
      bool compact = false,
      double textScale = 1.0,
      Brightness brightness = Brightness.light,
    }) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final calls = <Map<String, dynamic>>[];
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: MediaQuery.withClampedTextScaling(
          minScaleFactor: textScale,
          maxScaleFactor: textScale,
          child: Scaffold(
            body: ClaimQuizSheet(
              scanPosition: const LatLng(51.5, -0.12),
              compact: compact,
              nearbyCallable: _nearbyEiir,
              positionProvider: () async => _fakePos(),
              startScoringCallable: (payload) {
                calls.add(payload);
                return Completer<HttpsCallableResult<dynamic>>().future;
              },
              onCompleted: (_) {},
            ),
          ),
        ),
      ));
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Claim this postbox!'));
      await tester.pump();
      return calls;
    }

    testWidgets('shows four cypher plates with names, no codes or points',
        (tester) async {
      await openQuiz(tester);
      expect(find.text('Which cypher is on this postbox?'), findsOneWidget);
      final plates =
          tester.widgetList<CypherPlate>(find.byType(CypherPlate)).toList();
      expect(plates, hasLength(4));
      expect(plates.map((p) => p.code), contains('EIIR'));
      expect(find.text('Elizabeth II'), findsOneWidget);
      expect(find.text('1952–2022'), findsOneWidget);
      // Raw codes are gone: the plate shows the letters.
      for (final p in plates) {
        expect(find.text(p.code), findsNothing);
      }
      expect(find.textContaining('pts'), findsNothing,
          reason: 'points would nudge a guess at the most valuable cypher');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a wrong pick shows the retry screen with the numeral tip',
        (tester) async {
      final calls = await openQuiz(tester);
      final wrong = tester
          .widgetList<CypherPlate>(find.byType(CypherPlate))
          .map((p) => p.code)
          .firstWhere((c) => c != 'EIIR');
      await tester.tap(_tile(wrong));
      await tester.pump();
      expect(find.text('Not quite!'), findsOneWidget);
      expect(find.textContaining('Roman numeral'), findsOneWidget);
      expect(calls, isEmpty);
    });

    testWidgets('the right pick claims and locks the grid', (tester) async {
      final calls = await openQuiz(tester);
      await tester.tap(_tile('EIIR'));
      await tester.pump();
      await _settle(tester);
      expect(calls, hasLength(1));
      expect(find.text('Correct! Claiming…'), findsOneWidget);
      for (final b in tester.widgetList<OutlinedButton>(
          find.ancestor(
              of: find.byType(CypherPlate),
              matching: find.byType(OutlinedButton)))) {
        expect(b.onPressed, isNull, reason: 'options stay disabled mid-claim');
      }
    });

    testWidgets('the guide link opens the Cypher guide', (tester) async {
      await openQuiz(tester);
      // The sheet animates continuously, so pump past the route transition
      // rather than waiting to settle.
      await tester.tap(find.text('Not sure? See the cypher guide'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(CypherGuideScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Which cypher is on this postbox?'), findsOneWidget);
    });

    for (final compact in [false, true]) {
      testWidgets(
          'large text lays out without overflow (compact: $compact, dark)',
          (tester) async {
        await openQuiz(tester,
            compact: compact, textScale: 1.3, brightness: Brightness.dark);
        expect(find.byType(CypherPlate), findsNWidgets(4));
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('watch quiz', () {
    testWidgets('tiles show the plate and name, and answer on tap',
        (tester) async {
      final answers = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WearClaimView(
            stage: WearClaimStage.quiz,
            signedIn: true,
            quizOptions: const ['EVIIR', 'EVIIIR'],
            onScan: () {},
            onClaim: () {},
            onQuizAnswer: answers.add,
            onDone: () {},
          ),
        ),
      ));
      expect(find.text('Which cypher?'), findsOneWidget);
      expect(find.byType(CypherPlate), findsNWidgets(2));
      expect(find.text(MonarchInfo.nameOf('EVIIIR')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('wear-quiz-EVIIIR')));
      await tester.tap(find.byKey(const ValueKey('wear-quiz-EVIIR')));
      expect(answers, ['EVIIIR', 'EVIIR']);
    });
  });
}
