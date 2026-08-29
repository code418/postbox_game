// Guest (signed-out) mode on the Wear OS shell.
//
// The watch deliberately has no login wall: discovery scanning (compass +
// claim-page scan) works without an account, sign-in lives on the last page
// of the shell, and only claiming requires auth (mirroring the server, where
// `nearbyPostboxes` allows unauthenticated scans but `startScoring` does not).
// These tests pin that shape so a refactor can't silently reintroduce the
// wall or drop the signed-out sign-in page.

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/user_repository.dart';
import 'package:postbox_game/wear/wear_home.dart';
import 'package:postbox_game/wear/wear_login_screen.dart';
import 'package:postbox_game/wear/wear_status_page.dart';

/// Minimal RC stub — out-of-band values so every getter falls back to its
/// hard-coded default (mirrors the stub in intro_test.dart).
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

/// Never invoked — render-only tests don't tap the sign-in button.
class _FakeGoogleSignIn extends Fake implements GoogleSignIn {}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  setUp(() {
    RemoteConfigService.instance =
        RemoteConfigService(remoteConfig: _StubRemoteConfig());
    // WearHome's first page subscribes to the compass EventChannel; with no
    // handler registered the channel reports a MissingPluginException through
    // FlutterError, which fails the test. Serve an OPEN, SILENT stream — a
    // compass that never reports, like real hardware warming up. Do NOT call
    // events.endOfStream() inside onListen: closing the stream there hangs
    // the first subscribing test in the file for the full 10-minute
    // testWidgets timeout (verified by bisection in this repo — the hang
    // presents as a post-body TimeoutException with a dart:isolate frame,
    // regardless of what the test itself does).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      const EventChannel('hemanthraj/flutter_compass'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
  });
  tearDown(RemoteConfigService.resetForTest);

  UserRepository buildRepo() => UserRepository(
        firebaseAuth: MockFirebaseAuth(signedIn: false),
        googleSignin: _FakeGoogleSignIn(),
        firestore: FakeFirebaseFirestore(),
      );

  testWidgets('signed-out shell: compass and claim scan pages are usable, '
      'sign-in replaces the status page', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: WearHome(signedIn: false, userRepository: buildRepo()),
    ));
    await tester.pump();

    // Page 1: compass discovery scan is offered without an account.
    expect(find.text('Tap to scan'), findsOneWidget);

    // Page 2: claim page sits in its ready state — the scan itself is not
    // gated on sign-in (only the claim CTA is, once results arrive).
    // fling, not drag: a positional drag under half the viewport extent
    // snaps back, so give the gesture velocity like a real swipe. Upward,
    // because the shell pages vertically (see wear_shell_paging_test.dart).
    await tester.fling(find.byType(PageView), const Offset(0, -300), 1500);
    await tester.pumpAndSettle();
    expect(find.text('Scan & Claim'), findsOneWidget);

    // Page 3: the Google sign-in screen takes the status page's slot.
    await tester.fling(find.byType(PageView), const Offset(0, -300), 1500);
    await tester.pumpAndSettle();
    expect(find.byType(WearLoginScreen), findsOneWidget);
    expect(find.text('Google Sign-In'), findsOneWidget);
    expect(find.byType(WearStatusPage), findsNothing);
    expect(find.text('Sign out'), findsNothing);
  });

  testWidgets('signed-in shell keeps the status page (with sign-out), '
      'not the login screen', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: WearHome(signedIn: true, userRepository: buildRepo()),
    ));
    await tester.pump();

    await tester.fling(find.byType(PageView), const Offset(0, -300), 1500);
    await tester.pumpAndSettle();
    await tester.fling(find.byType(PageView), const Offset(0, -300), 1500);
    await tester.pumpAndSettle();

    expect(find.byType(WearStatusPage), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.byType(WearLoginScreen), findsNothing);
  });
}
