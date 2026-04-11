import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/app_preferences.dart';
import 'package:postbox_game/main.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/streak_service.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/user_repository.dart';
import 'package:postbox_game/validators.dart';

// ---------------------------------------------------------------------------
// Firebase mock setup
// ---------------------------------------------------------------------------

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
      await tester.pumpWidget(const PostboxGame());
      await tester.pump();
      expect(find.byType(MaterialApp), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // AppSpacing unit tests
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
      await repo.signUp(email: 'test@example.com', password: 'password123');

      final uid = mockAuth.currentUser?.uid;
      expect(uid, isNotNull);

      final doc = await fakeFirestore.collection('users').doc(uid).get();
      expect(doc.data()?['displayName'], equals('test'));
    });

    test('signUp writes email to Firestore', () async {
      await repo.signUp(email: 'alice@example.com', password: 'password');
      final uid = mockAuth.currentUser?.uid;
      expect(uid, isNotNull);
      final doc = await fakeFirestore.collection('users').doc(uid).get();
      expect(doc.data()?['email'], equals('alice@example.com'));
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
      final signedInRepo = UserRepository(firebaseAuth: auth, firestore: fakeFirestore);
      expect(await signedInRepo.isSignedIn(), isTrue);
    });

    test('signUp uses Player_ fallback for profane email prefix', () async {
      // Email prefix "cunt" fails the profanity filter.
      await repo.signUp(email: 'cunt@example.com', password: 'password123');
      final uid = mockAuth.currentUser?.uid;
      expect(uid, isNotNull);
      final doc = await fakeFirestore.collection('users').doc(uid).get();
      final name = doc.data()?['displayName'] as String?;
      expect(name, isNotNull);
      expect(name!.startsWith('Player_'), isTrue,
          reason: 'Profane email prefix should fall back to Player_<uid>');
    });
  });

  // ---------------------------------------------------------------------------
  // Validators unit tests
  // ---------------------------------------------------------------------------

  group('Validators', () {
    group('isValidEmail', () {
      test('accepts valid emails', () {
        expect(Validators.isValidEmail('alice@example.com'), isTrue);
        expect(Validators.isValidEmail('user+tag@sub.domain.org'), isTrue);
      });

      test('rejects invalid emails', () {
        expect(Validators.isValidEmail(''), isFalse);
        expect(Validators.isValidEmail('notanemail'), isFalse);
        expect(Validators.isValidEmail('@nodomain'), isFalse);
      });
    });

    group('isValidDisplayName', () {
      test('accepts normal names', () {
        expect(Validators.isValidDisplayName('Alice'), isTrue);
        expect(Validators.isValidDisplayName('Postbox Pete'), isTrue);
        expect(Validators.isValidDisplayName('ab'), isTrue);
      });

      test('rejects names that are too short or too long', () {
        expect(Validators.isValidDisplayName('a'), isFalse);
        expect(Validators.isValidDisplayName(''), isFalse);
        expect(Validators.isValidDisplayName('a' * 31), isFalse);
      });

      test('rejects profane names', () {
        expect(Validators.isValidDisplayName('cunt'), isFalse);
        expect(Validators.isValidDisplayName('MyBellend'), isFalse);
        expect(Validators.isValidDisplayName('WANKER'), isFalse);
      });

      test('allows 30-char names', () {
        expect(Validators.isValidDisplayName('a' * 30), isTrue);
      });
    });
  });

  // ---------------------------------------------------------------------------
  // StreakService unit tests
  // ---------------------------------------------------------------------------

  group('StreakService', () {
    late FakeFirebaseFirestore fakeFirestore;
    late MockFirebaseAuth mockAuth;
    late StreakService streakService;
    late String uid;

    /// Returns today's date string in YYYY-MM-DD using local time, matching the
    /// logic inside StreakService._today.
    String localDateString(DateTime d) {
      return '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
    }

    setUp(() {
      fakeFirestore = FakeFirebaseFirestore();
      mockAuth = MockFirebaseAuth(signedIn: true);
      streakService = StreakService(firestore: fakeFirestore, auth: mockAuth);
      uid = mockAuth.currentUser!.uid;
    });

    test('first claim sets streak to 1 and records today', () async {
      await streakService.updateStreakAfterClaim();
      final doc = await fakeFirestore.collection('users').doc(uid).get();
      expect(doc.data()?['streak'], equals(1));
      expect(doc.data()?['lastClaimDate'],
          equals(localDateString(DateTime.now())));
    });

    test('claiming again today leaves streak unchanged', () async {
      final today = localDateString(DateTime.now());
      await fakeFirestore
          .collection('users')
          .doc(uid)
          .set({'streak': 5, 'lastClaimDate': today});

      await streakService.updateStreakAfterClaim();

      final doc = await fakeFirestore.collection('users').doc(uid).get();
      expect(doc.data()?['streak'], equals(5),
          reason: 'Same-day re-claim must not increment streak');
    });

    test('claiming on consecutive day increments streak', () async {
      final yesterday =
          localDateString(DateTime.now().subtract(const Duration(days: 1)));
      await fakeFirestore
          .collection('users')
          .doc(uid)
          .set({'streak': 3, 'lastClaimDate': yesterday});

      await streakService.updateStreakAfterClaim();

      final doc = await fakeFirestore.collection('users').doc(uid).get();
      expect(doc.data()?['streak'], equals(4));
    });

    test('claiming after a gap resets streak to 1', () async {
      final twoDaysAgo =
          localDateString(DateTime.now().subtract(const Duration(days: 2)));
      await fakeFirestore
          .collection('users')
          .doc(uid)
          .set({'streak': 10, 'lastClaimDate': twoDaysAgo});

      await streakService.updateStreakAfterClaim();

      final doc = await fakeFirestore.collection('users').doc(uid).get();
      expect(doc.data()?['streak'], equals(1));
    });

    test('streakStream emits null when document has no streak field', () async {
      await fakeFirestore
          .collection('users')
          .doc(uid)
          .set({'displayName': 'Test'});

      final value = await streakService.streakStream().first;
      expect(value, isNull);
    });

    test('streakStream emits current streak value', () async {
      await fakeFirestore
          .collection('users')
          .doc(uid)
          .set({'streak': 7, 'lastClaimDate': '2026-01-01'});

      final value = await streakService.streakStream().first;
      expect(value, equals(7));
    });
  });

  // ---------------------------------------------------------------------------
  // AppPreferences unit tests
  // ---------------------------------------------------------------------------

  group('AppPreferences.formatDistance', () {
    test('formats meters correctly', () {
      expect(AppPreferences.formatDistance(540.0, DistanceUnit.meters),
          equals('540 m'));
      expect(AppPreferences.formatDistance(30.0, DistanceUnit.meters),
          equals('30 m'));
    });

    test('formats miles to 1 decimal place', () {
      // 1000m ≈ 0.621371 mi
      final result =
          AppPreferences.formatDistance(1000.0, DistanceUnit.miles);
      expect(result, endsWith(' mi'));
      expect(result, contains('.'));
    });

    test('formatShortDistance uses yards for miles mode', () {
      // 30m ≈ 32 yards
      final result =
          AppPreferences.formatShortDistance(30.0, DistanceUnit.miles);
      expect(result, endsWith(' yd'));
      final yards = int.parse(result.split(' ').first);
      expect(yards, greaterThan(30));
      expect(yards, lessThan(35));
    });

    test('formatShortDistance uses meters in metric mode', () {
      expect(AppPreferences.formatShortDistance(30.0, DistanceUnit.meters),
          equals('30 m'));
    });
  });

  // ---------------------------------------------------------------------------
  // MonarchInfo consistency tests
  // ---------------------------------------------------------------------------

  group('MonarchInfo', () {
    test('all ciphers in "all" have a label', () {
      for (final cipher in MonarchInfo.all) {
        expect(MonarchInfo.labels.containsKey(cipher), isTrue,
            reason: '$cipher missing from labels');
      }
    });

    test('all ciphers in "all" have a color', () {
      for (final cipher in MonarchInfo.all) {
        expect(MonarchInfo.colors.containsKey(cipher), isTrue,
            reason: '$cipher missing from colors');
      }
    });

    test('rareCiphers is a subset of "all"', () {
      for (final cipher in MonarchInfo.rareCiphers) {
        expect(MonarchInfo.all.contains(cipher), isTrue,
            reason: '$cipher in rareCiphers but not in all');
      }
    });

    test('historicCiphers is a subset of "all"', () {
      for (final cipher in MonarchInfo.historicCiphers) {
        expect(MonarchInfo.all.contains(cipher), isTrue,
            reason: '$cipher in historicCiphers but not in all');
      }
    });

    test('rareCiphers and historicCiphers are disjoint', () {
      final overlap =
          MonarchInfo.rareCiphers.intersection(MonarchInfo.historicCiphers);
      expect(overlap, isEmpty,
          reason: 'A cipher should not be both rare and historic');
    });
  });
}
