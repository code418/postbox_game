// Pins the paging axis of the Wear OS shell.
//
// Wear OS reserves the left-to-right swipe as the system dismiss gesture:
// on a real watch a rightward swipe (which on a ~1.3" round screen almost
// always starts near the left edge) is claimed by the system and throws the
// user back to the watchface. The shell must therefore page VERTICALLY —
// horizontal swipes must do nothing (they belong to the OS), vertical swipes
// move between pages, and the rotary crown still switches whole pages.
//
// Setup notes (compass EventChannel stub, RC stub) mirror
// wear_guest_mode_test.dart — see the comments there for why the compass
// stream must stay open and silent.

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/user_repository.dart';
import 'package:postbox_game/wear/wear_home.dart';

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

  Future<void> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: WearHome(signedIn: false, userRepository: buildRepo()),
    ));
    await tester.pump();
  }

  testWidgets('vertical swipes page through the shell, up = forward',
      (tester) async {
    await pumpShell(tester);
    expect(find.text('Tap to scan'), findsOneWidget);

    // Swipe up → claim page.
    await tester.fling(find.byType(PageView), const Offset(0, -300), 1500);
    await tester.pumpAndSettle();
    expect(find.text('Scan & Claim'), findsOneWidget);

    // Swipe back down → compass again.
    await tester.fling(find.byType(PageView), const Offset(0, 300), 1500);
    await tester.pumpAndSettle();
    expect(find.text('Tap to scan'), findsOneWidget);
  });

  testWidgets(
      'horizontal swipes do not page — the right swipe belongs to the '
      'system dismiss gesture', (tester) async {
    await pumpShell(tester);

    // A leftward fling (the old "next page" gesture) must be inert.
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1500);
    await tester.pumpAndSettle();
    expect(find.text('Tap to scan'), findsOneWidget);

    // A rightward fling must be inert too (on-device the system usually
    // claims it before the app; when it doesn't, it must not page either).
    await tester.fling(find.byType(PageView), const Offset(300, 0), 1500);
    await tester.pumpAndSettle();
    expect(find.text('Tap to scan'), findsOneWidget);
  });

  testWidgets(
      'a single rotary tick moves exactly one whole page and settles there',
      (tester) async {
    await pumpShell(tester);

    // The rotary crown arrives as a PointerScrollEvent. One small tick must
    // switch to the NEXT page (discrete navigation), not nudge the pager by
    // the raw scroll delta — a 56 px nudge on its own would snap straight
    // back to the compass page.
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
        pointer.hover(tester.getCenter(find.byType(PageView))));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 56)));
    await tester.pumpAndSettle();
    expect(find.text('Scan & Claim'), findsOneWidget);

    // And one tick the other way returns to the compass.
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -56)));
    await tester.pumpAndSettle();
    expect(find.text('Tap to scan'), findsOneWidget);
  });

  testWidgets('page indicator is a vertical dot column on the right edge',
      (tester) async {
    await pumpShell(tester);

    // The three dots are the shell's only AnimatedContainers (the pages have
    // none — verified when this test was written).
    final dots = find.byType(AnimatedContainer);
    expect(dots, findsNWidgets(3));

    final centers =
        List.generate(3, (i) => tester.getCenter(dots.at(i)), growable: false);
    final screenWidth = tester.getSize(find.byType(WearHome)).width;

    for (final c in centers) {
      // On the right edge, not along the bottom.
      expect(c.dx, greaterThan(screenWidth * 0.9));
      expect(c.dx, moreOrLessEquals(centers.first.dx, epsilon: 1));
    }
    // Stacked vertically, in page order.
    expect(centers[0].dy, lessThan(centers[1].dy));
    expect(centers[1].dy, lessThan(centers[2].dy));
  });
}
