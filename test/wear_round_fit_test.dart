// Every Wear OS page state must fit the round display.
//
// Play rejected 1.5.1 (wear 10021, Sept 2026) under "Wear App Quality
// Guidelines: Watch shapes — no text or controls cut off by the screen
// edges". The evidence was the login page after a failed sign-in on a watch
// with no Google account: the error line sat low in the circle, where the
// chord is narrow, and read "Google account on this wat". The emulator's
// square screencaps never show this because they include the corners a
// physical round watch does not have.
//
// This test encodes Play's rule directly: rendered at the Pixel Watch /
// "Small Round" geometry (192 dp diameter), the bounding box of every text,
// icon, button and indicator dot must lie inside the inscribed circle. It
// loads the real Roboto faces from the Flutter SDK cache so text measures
// as it does on the watch — the placeholder test font is ~2x wider and
// would wrap everything.

import 'dart:io';
import 'dart:math' as math;

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/user_repository.dart';
import 'package:postbox_game/wear/wear_claim_page.dart';
import 'package:postbox_game/wear/wear_home.dart';
import 'package:postbox_game/wear/wear_login_screen.dart';
import 'package:postbox_game/wear/wear_round_inset.dart';
import 'package:postbox_game/wear/wear_theme.dart';

/// Pixel Watch / Wear "Small Round" emulator: 384 px at 2x = 192 dp.
const double _diameter = 192;

class _StubRemoteConfig extends Fake implements FirebaseRemoteConfig {
  @override
  bool getBool(String key) => false;
  @override
  String getString(String key) => '';
  @override
  double getDouble(String key) => 0;
  @override
  int getInt(String key) => 0;
}

/// Reproduces the reviewer's watch: no Google account, so the plugin fails
/// with the "No credential available" description the app maps to its
/// longest login error.
class _NoAccountGoogleSignIn extends Fake implements GoogleSignIn {
  @override
  Future<GoogleSignInAccount> authenticate({
    List<String> scopeHint = const [],
  }) async {
    throw const GoogleSignInException(
      code: GoogleSignInExceptionCode.unknownError,
      description: '$kNoGoogleCredentialPrefix: no accounts',
    );
  }
}

Future<void> _loadRoboto() async {
  final root = Platform.environment['FLUTTER_ROOT'] ??
      // .../flutter/bin/cache/dart-sdk/bin/dart → four levels up.
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path;
  final dir = Directory('$root/bin/cache/artifacts/material_fonts');
  expect(dir.existsSync(), isTrue,
      reason: 'Roboto not found at ${dir.path}; is FLUTTER_ROOT set?');
  final loader = FontLoader(WearTheme.fontFamily);
  for (final face in const [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
  ]) {
    final bytes = await File('${dir.path}/$face').readAsBytes();
    loader.addFont(Future.value(bytes.buffer.asByteData()));
  }
  await loader.load();
}

/// Fails if any visible text, icon, button or indicator dot pokes outside
/// the inscribed circle. The bounding-rect check is deliberately stricter
/// than the painted shape (a stadium button's corners are empty), so a pass
/// here is a safe margin on the physical bezel.
void expectFitsRoundScreen(WidgetTester tester, {String? state}) {
  final centre = const Offset(_diameter / 2, _diameter / 2);
  const radius = _diameter / 2;
  final visible = find.byWidgetPredicate((w) =>
      w is Text ||
      w is Icon ||
      w is FaIcon ||
      w is ButtonStyleButton ||
      w is CircularProgressIndicator ||
      w is AnimatedContainer);
  expect(visible, findsWidgets, reason: 'nothing rendered for $state');
  final offenders = <String>[];
  for (final element in visible.evaluate()) {
    final rect = tester.getRect(find.byElementPredicate((e) => e == element));
    if (rect.isEmpty) continue;
    final worst = [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ].map((c) => (c - centre).distance).reduce(math.max);
    if (worst > radius + 0.5) {
      offenders.add('${element.widget.runtimeType} $rect '
          '(corner ${worst.toStringAsFixed(1)} dp from centre, '
          'radius ${radius.toStringAsFixed(0)})');
    }
  }
  expect(offenders, isEmpty,
      reason: 'clipped by the round bezel${state == null ? '' : ' in $state'}');
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    await _loadRoboto();
  });

  setUp(() {
    RemoteConfigService.instance =
        RemoteConfigService(remoteConfig: _StubRemoteConfig());
    // Silent, open compass stream — see wear_guest_mode_test.dart.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      const EventChannel('hemanthraj/flutter_compass'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
  });
  tearDown(RemoteConfigService.resetForTest);

  Future<void> pumpWatch(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(_diameter * 2, _diameter * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: WearTheme.dark, home: home));
    await tester.pump();
  }

  UserRepository repo({GoogleSignIn? google}) => UserRepository(
        firebaseAuth: MockFirebaseAuth(signedIn: false),
        googleSignin: google ?? _NoAccountGoogleSignIn(),
        firestore: FakeFirebaseFirestore(),
      );

  Future<void> nextPage(WidgetTester tester) async {
    await tester.fling(find.byType(PageView), const Offset(0, -150), 1500);
    await tester.pumpAndSettle();
  }

  test('WearRoundInset confines its child to the inscribed square', () {
    // (1 - 1/√2) / 2 of the diameter per side — androidx BoxInsetLayout's
    // FACTOR. For 192 dp that is ~28 dp, leaving a ~136 dp square.
    expect(WearRoundInset.insetFactor, moreOrLessEquals(0.146447, epsilon: 1e-6));
    expect(WearRoundInset.insetFor(const Size(192, 192)),
        moreOrLessEquals(28.1, epsilon: 0.1));
  });

  testWidgets('signed-out shell: compass, claim and login pages fit',
      (tester) async {
    await pumpWatch(tester, WearHome(signedIn: false, userRepository: repo()));
    expectFitsRoundScreen(tester, state: 'compass initial');
    await nextPage(tester);
    expectFitsRoundScreen(tester, state: 'claim ready');
    await nextPage(tester);
    expect(find.byType(WearLoginScreen), findsOneWidget);
    expectFitsRoundScreen(tester, state: 'login');
  });

  testWidgets(
      'login page after a no-Google-account failure fits '
      '(the state Play rejected)', (tester) async {
    await pumpWatch(tester, WearLoginScreen(userRepository: repo()));
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.text('No Google account on this watch'), findsOneWidget);
    expectFitsRoundScreen(tester, state: 'login error');
  });

  testWidgets('signed-in shell: status page fits', (tester) async {
    await pumpWatch(tester, WearHome(signedIn: true, userRepository: repo()));
    await nextPage(tester);
    await nextPage(tester);
    expect(find.text('Sign out'), findsOneWidget);
    expectFitsRoundScreen(tester, state: 'status');
  });

  group('claim page states fit', () {
    // Worst-case content for each stage: longest messages, two two-line quiz
    // options, a multi-claim success with points and a streak line.
    final cases = <String, WearClaimView>{
      'ready': WearClaimView(
        stage: WearClaimStage.ready,
        signedIn: true,
        onScan: () {},
        onClaim: () {},
        onQuizAnswer: (_) {},
        onDone: () {},
      ),
      'scanning': WearClaimView(
        stage: WearClaimStage.scanning,
        signedIn: true,
        onScan: () {},
        onClaim: () {},
        onQuizAnswer: (_) {},
        onDone: () {},
      ),
      'found signed out': WearClaimView(
        stage: WearClaimStage.found,
        signedIn: false,
        count: 12,
        onScan: () {},
        onClaim: () {},
        onQuizAnswer: (_) {},
        onDone: () {},
      ),
      'found all claimed': WearClaimView(
        stage: WearClaimStage.found,
        signedIn: true,
        count: 12,
        claimedToday: 12,
        onScan: () {},
        onClaim: () {},
        onQuizAnswer: (_) {},
        onDone: () {},
      ),
      'empty': WearClaimView(
        stage: WearClaimStage.empty,
        signedIn: true,
        onScan: () {},
        onClaim: () {},
        onQuizAnswer: (_) {},
        onDone: () {},
      ),
      'error longest message': WearClaimView(
        stage: WearClaimStage.error,
        signedIn: true,
        errorMessage: 'Location denied. Enable in settings.',
        onScan: () {},
        onClaim: () {},
        onQuizAnswer: (_) {},
        onDone: () {},
      ),
      'quiz after a miss': WearClaimView(
        stage: WearClaimStage.quiz,
        signedIn: true,
        quizOptions: const ['SCOTTISH_CROWN', 'EVIIIR'],
        quizMissed: true,
        onScan: () {},
        onClaim: () {},
        onQuizAnswer: (_) {},
        onDone: () {},
      ),
      'success with streak': WearClaimView(
        stage: WearClaimStage.success,
        signedIn: true,
        claimedCount: 3,
        pointsEarned: 27,
        streakStream: Stream<int?>.value(12),
        onScan: () {},
        onClaim: () {},
        onQuizAnswer: (_) {},
        onDone: () {},
      ),
    };

    for (final entry in cases.entries) {
      testWidgets(entry.key, (tester) async {
        await pumpWatch(tester, Scaffold(body: entry.value));
        await tester.pump();
        expectFitsRoundScreen(tester, state: entry.key);
      });
    }
  });
}
