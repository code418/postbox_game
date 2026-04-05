import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/main.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/user_repository.dart';

// ---------------------------------------------------------------------------
// Firebase mock setup
// ---------------------------------------------------------------------------

/// Call once per test run (or in setUp) to initialise the Firebase platform
/// mock so that Firebase.initializeApp() succeeds without hitting real servers.
Future<void> setupFirebaseMocks() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  await Firebase.initializeApp();
}

// ---------------------------------------------------------------------------
// Widget-level smoke tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(setupFirebaseMocks);

  group('App smoke tests', () {
    testWidgets('PostboxGame widget tree renders without crashing', (tester) async {
      await tester.pumpWidget(PostboxGame());
      await tester.pump(); // process one frame
      // Should show SplashScreen or LoginScreen (Firebase is mocked)
      expect(find.byType(MaterialApp), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // AppSpacing unit tests (from phase4-polish)
  // ---------------------------------------------------------------------------

  group('AppSpacing', () {
    test('spacing scale is strictly increasing', () {
      expect(AppSpacing.xs, lessThan(AppSpacing.sm));
      expect(AppSpacing.sm, lessThan(AppSpacing.md));
      expect(AppSpacing.md, lessThan(AppSpacing.lg));
      expect(AppSpacing.lg, lessThan(AppSpacing.xl));
      expect(AppSpacing.xl, lessThan(AppSpacing.xxl));
    });

    test('xs is positive', () {
      expect(AppSpacing.xs, greaterThan(0));
    });
  });

  // ---------------------------------------------------------------------------
  // UserRepository unit tests
  // ---------------------------------------------------------------------------

  group('UserRepository', () {
    late FakeFirebaseFirestore fakeFirestore;
    late MockFirebaseAuth mockAuth;
    late UserRepository repo;

    setUp(() {
      fakeFirestore = FakeFirebaseFirestore();
      mockAuth = MockFirebaseAuth();
      repo = UserRepository(
        firebaseAuth: mockAuth,
        firestore: fakeFirestore,
      );
    });

    test('signUp writes displayName to Firestore', () async {
      // MockFirebaseAuth creates a user automatically on signUp.
      await repo.signUp(email: 'test@example.com', password: 'password123');

      final uid = mockAuth.currentUser?.uid;
      expect(uid, isNotNull);

      final doc = await fakeFirestore.collection('users').doc(uid).get();
      expect(doc.data()?['displayName'], equals('test'));
    });

    test('getDisplayName returns stored name', () async {
      const uid = 'user-abc';
      await fakeFirestore.collection('users').doc(uid).set({'displayName': 'Postbox Pete'});

      final name = await repo.getDisplayName(uid);
      expect(name, equals('Postbox Pete'));
    });

    test('getDisplayName returns null for unknown uid', () async {
      final name = await repo.getDisplayName('nonexistent-uid');
      expect(name, isNull);
    });

    test('isSignedIn returns false when no user', () async {
      final signedIn = await repo.isSignedIn();
      expect(signedIn, isFalse);
    });

    test('isSignedIn returns true when a user is signed in', () async {
      final auth = MockFirebaseAuth(signedIn: true);
      final repo = UserRepository(firebaseAuth: auth, firestore: fakeFirestore);
      expect(await repo.isSignedIn(), isTrue);
    });

    test('signUp writes email to Firestore', () async {
      await repo.signUp(email: 'alice@example.com', password: 'password');
      final uid = mockAuth.currentUser?.uid;
      expect(uid, isNotNull);
      final doc = await fakeFirestore
          .collection('users')
          .doc(uid)
          .get();
      expect(doc.data()?['email'], equals('alice@example.com'));
    });
  });

}
