import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:postbox_game/app_preferences.dart';
import 'package:postbox_game/authentication_bloc/bloc.dart';
import 'package:postbox_game/claim_history_screen.dart';
import 'package:postbox_game/fuzzy_compass.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/london_date.dart';
import 'package:postbox_game/main.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/settings_screen.dart';
import 'package:postbox_game/streak_service.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/user_profile_page.dart';
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

    test('signUp does not write to Firestore (handled by Cloud Function)', () async {
      // displayName and all profile fields are written by the onUserCreated
      // Cloud Function (server-side), not by the client. This prevents clients
      // from bypassing the profanity filter via direct Firestore writes.
      await repo.signUp(email: 'test@example.com', password: 'password123');
      final uid = mockAuth.currentUser?.uid;
      expect(uid, isNotNull);
      final doc = await fakeFirestore.collection('users').doc(uid).get();
      expect(doc.exists, isFalse,
          reason: 'signUp must not create a Firestore document; '
              'the onUserCreated Cloud Function handles this server-side');
    });

    test('signUp sets displayName in Firebase Auth', () async {
      await repo.signUp(email: 'alice@example.com', password: 'password');
      final displayName = mockAuth.currentUser?.displayName;
      expect(displayName, equals('alice'));
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

    test('signUp uses Player_ fallback in Auth displayName for profane email prefix', () async {
      // Email prefix "cunt" fails the profanity filter; Auth displayName should
      // use the Player_<uid> fallback. No Firestore write occurs client-side.
      await repo.signUp(email: 'cunt@example.com', password: 'password123');
      final displayName = mockAuth.currentUser?.displayName;
      expect(displayName, isNotNull);
      expect(displayName!.startsWith('Player_'), isTrue,
          reason: 'Profane email prefix should fall back to Player_<uid> in Auth profile');
    });

    test('sendPasswordResetEmail completes without error for valid email', () async {
      // The real Firebase sends an email; the mock just completes.
      // We verify the method chain reaches FirebaseAuth without throwing.
      await expectLater(
        repo.sendPasswordResetEmail('alice@example.com'),
        completes,
      );
    });

    test('changePassword throws when no user is signed in', () async {
      // repo uses MockFirebaseAuth() with no signed-in user (mockAuth default).
      expect(
        () => repo.changePassword(
          currentPassword: 'old',
          newPassword: 'newpassword',
        ),
        throwsA(isA<FirebaseAuthException>()),
      );
    });

    test('changePassword completes for a signed-in email user', () async {
      // Sign up first so there is a current user with an email address.
      await repo.signUp(email: 'bob@example.com', password: 'password123');
      // MockFirebaseAuth.reauthenticateWithCredential always succeeds (no real
      // credential validation in the mock), so this verifies the call chain.
      await expectLater(
        repo.changePassword(
          currentPassword: 'password123',
          newPassword: 'newpassword123',
        ),
        completes,
      );
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

    group('isValidPassword', () {
      test('accepts passwords with 6 or more characters', () {
        expect(Validators.isValidPassword('123456'), isTrue);
        expect(Validators.isValidPassword('password'), isTrue);
        expect(Validators.isValidPassword('!@#\$%^'), isTrue);
      });

      test('rejects passwords shorter than 6 characters', () {
        expect(Validators.isValidPassword(''), isFalse);
        expect(Validators.isValidPassword('12345'), isFalse);
      });

      test('accepts any character type (matches Firebase Auth minimum)', () {
        expect(Validators.isValidPassword('abc def'), isTrue);
        expect(Validators.isValidPassword('      '), isTrue); // 6 spaces
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

    group('displayNameError', () {
      test('returns null for valid names', () {
        expect(Validators.displayNameError('Alice'), isNull);
        expect(Validators.displayNameError('Postbox Pete'), isNull);
        expect(Validators.displayNameError('a' * 30), isNull);
      });

      test('returns length error for too-short names', () {
        expect(Validators.displayNameError('a'),
            equals('Name must be at least 2 characters'));
        expect(Validators.displayNameError(''),
            equals('Name must be at least 2 characters'));
        expect(Validators.displayNameError('   '),
            equals('Name must be at least 2 characters'));
      });

      test('returns length error for too-long names', () {
        expect(Validators.displayNameError('a' * 31),
            equals('Name must be 30 characters or fewer'));
      });

      test('returns profanity error for blocked names', () {
        expect(Validators.displayNameError('BigWanker'),
            equals("That name isn't allowed"));
        expect(Validators.displayNameError('CUNT'),
            equals("That name isn't allowed"));
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

    setUp(() {
      fakeFirestore = FakeFirebaseFirestore();
      mockAuth = MockFirebaseAuth(signedIn: true);
      streakService = StreakService(firestore: fakeFirestore, auth: mockAuth);
      uid = mockAuth.currentUser!.uid;
    });

    // Streak writes (lastClaimDate, streak) are performed server-side in
    // startScoring (Admin SDK) because Firestore rules restrict client writes
    // on users/{uid} to the friends array only. Only the read-side (streakStream)
    // is tested here.

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
          .set({'streak': 7, 'lastClaimDate': todayLondon()});

      final value = await streakService.streakStream().first;
      expect(value, equals(7));
    });

    test('streakStream emits null when no user is signed in', () async {
      // Service with a signed-out auth instance should return null immediately
      // rather than throwing or hanging.
      final signedOutAuth = MockFirebaseAuth();
      final service = StreakService(firestore: fakeFirestore, auth: signedOutAuth);
      final value = await service.streakStream().first;
      expect(value, isNull);
    });

    test('streakStream handles streak stored as double (num cast)', () async {
      // Firestore may return numeric fields as double even when originally
      // written as int. The StreakService must handle this via (num?)?.toInt().
      await fakeFirestore
          .collection('users')
          .doc(uid)
          .set({'streak': 3.0, 'lastClaimDate': todayLondon()});

      final value = await streakService.streakStream().first;
      expect(value, equals(3));
      expect(value, isA<int>());
    });

    test('streakStream returns stored streak when last claim was yesterday',
        () async {
      await fakeFirestore
          .collection('users')
          .doc(uid)
          .set({'streak': 4, 'lastClaimDate': yesterdayLondon()});

      final value = await streakService.streakStream().first;
      expect(value, equals(4));
    });

    test('streakStream returns 0 when last claim is older than yesterday',
        () async {
      // A user who last claimed three days ago has a broken streak; the UI
      // must reflect that immediately rather than showing the stale value.
      await fakeFirestore
          .collection('users')
          .doc(uid)
          .set({'streak': 9, 'lastClaimDate': '2024-06-01'});

      final value = await streakService.streakStream().first;
      expect(value, equals(0));
    });

    test('streakStream returns 0 when lastClaimDate is missing but streak set',
        () async {
      // Defensive: if streak is present without lastClaimDate we cannot verify
      // freshness so treat the streak as broken.
      await fakeFirestore
          .collection('users')
          .doc(uid)
          .set({'streak': 5});

      final value = await streakService.streakStream().first;
      expect(value, equals(0));
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
  // FuzzyCompass unit tests
  // ---------------------------------------------------------------------------

  group('FuzzyCompass.vagueLabel', () {
    test('returns None for zero', () {
      expect(FuzzyCompass.vagueLabel(0), equals('None'));
    });
    test('returns None for negative', () {
      expect(FuzzyCompass.vagueLabel(-5), equals('None'));
    });
    test('returns One for count 1', () {
      expect(FuzzyCompass.vagueLabel(1), equals('One'));
    });
    test('returns A few for count 2', () {
      expect(FuzzyCompass.vagueLabel(2), equals('A few'));
    });
    test('returns A few for count 3', () {
      expect(FuzzyCompass.vagueLabel(3), equals('A few'));
    });
    test('returns Several for count 4+', () {
      expect(FuzzyCompass.vagueLabel(4), equals('Several'));
      expect(FuzzyCompass.vagueLabel(100), equals('Several'));
    });
  });

  group('FuzzyCompass.to8Sectors', () {
    test('sums N and NNE into N sector', () {
      final result = FuzzyCompass.to8Sectors({'N': 3, 'NNE': 2});
      expect(result['N'], equals(5));
    });

    test('each 8-wind sector is present in output', () {
      final result = FuzzyCompass.to8Sectors({});
      for (final dir in ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW']) {
        expect(result.containsKey(dir), isTrue, reason: '$dir missing from output');
      }
    });

    test('missing 16-wind directions contribute 0', () {
      final result = FuzzyCompass.to8Sectors({});
      for (final v in result.values) {
        expect(v, equals(0));
      }
    });

    test('all 16 winds sum correctly into 8 sectors', () {
      final counts = {
        'N': 1, 'NNE': 1,
        'NE': 1, 'ENE': 1,
        'E': 1, 'ESE': 1,
        'SE': 1, 'SSE': 1,
        'S': 1, 'SSW': 1,
        'SW': 1, 'WSW': 1,
        'W': 1, 'WNW': 1,
        'NW': 1, 'NNW': 1,
      };
      final result = FuzzyCompass.to8Sectors(counts);
      for (final v in result.values) {
        expect(v, equals(2), reason: 'each 8-sector should sum 2 x 1');
      }
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

    test('all ciphers in "all" have a points value', () {
      for (final cipher in MonarchInfo.all) {
        expect(MonarchInfo.points.containsKey(cipher), isTrue,
            reason: '$cipher missing from points');
      }
    });

    test('getPoints returns the mapped value for known ciphers', () {
      expect(MonarchInfo.getPoints('EIIR'), equals(2));
      expect(MonarchInfo.getPoints('GR'), equals(4));
      expect(MonarchInfo.getPoints('GVR'), equals(4));
      expect(MonarchInfo.getPoints('GVIR'), equals(4));
      expect(MonarchInfo.getPoints('SCOTTISH_CROWN'), equals(4));
      expect(MonarchInfo.getPoints('VR'), equals(7));
      expect(MonarchInfo.getPoints('EVIIR'), equals(9));
      expect(MonarchInfo.getPoints('CIIIR'), equals(9));
      expect(MonarchInfo.getPoints('EVIIIR'), equals(12));
    });

    test('getPoints returns 2 for unknown cipher', () {
      expect(MonarchInfo.getPoints('UNKNOWN'), equals(2));
    });

    test('all points values are positive', () {
      for (final entry in MonarchInfo.points.entries) {
        expect(entry.value, greaterThan(0),
            reason: '${entry.key} has non-positive point value');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // JamesMessages unit tests
  // ---------------------------------------------------------------------------

  group('JamesMessages', () {
    test('all JamesMessage constants have non-empty keys', () {
      final messages = [
        JamesMessages.navNearby,
        JamesMessages.navClaim,
        JamesMessages.navScores,
        JamesMessages.navFriends,
        JamesMessages.navFriendsLeaderboard,
        JamesMessages.navLifetimeScores,
        JamesMessages.idle,
        JamesMessages.nearbyNoneFound,
        JamesMessages.nearbyErrorPermission,
        JamesMessages.nearbyErrorGeneral,
        JamesMessages.errorOffline,
        JamesMessages.claimOutOfRange,
        JamesMessages.claimSuccessRare,
        JamesMessages.claimSuccessStandard,
        JamesMessages.claimScanEmpty,
        JamesMessages.claimErrorAlreadyClaimed,
        JamesMessages.claimErrorOutOfRange,
        JamesMessages.claimErrorGeneral,
        JamesMessages.quizFailed,
        JamesMessages.introStep2,
        JamesMessages.introStep3,
      ];
      for (final msg in messages) {
        expect(msg.key, isNotEmpty, reason: 'key must be non-empty');
      }
    });

    test('all JamesMessage constants resolve to non-empty strings', () {
      final messages = [
        JamesMessages.navNearby,
        JamesMessages.navClaim,
        JamesMessages.navScores,
        JamesMessages.navFriends,
        JamesMessages.navFriendsLeaderboard,
        JamesMessages.navLifetimeScores,
        JamesMessages.idle,
        JamesMessages.nearbyNoneFound,
        JamesMessages.nearbyErrorPermission,
        JamesMessages.nearbyErrorGeneral,
        JamesMessages.errorOffline,
        JamesMessages.claimOutOfRange,
        JamesMessages.claimScanEmpty,
        JamesMessages.claimSuccessRare,
        JamesMessages.claimSuccessStandard,
        JamesMessages.claimErrorAlreadyClaimed,
        JamesMessages.claimErrorOutOfRange,
        JamesMessages.claimErrorGeneral,
        JamesMessages.quizFailed,
        JamesMessages.introStep2,
        JamesMessages.introStep3,
      ];
      for (final msg in messages) {
        expect(msg.resolve(), isNotEmpty, reason: '${msg.key} must resolve to non-empty string');
      }
    });

    test('forTabIndex returns correct nav messages', () {
      expect(JamesMessages.forTabIndex(0), equals(JamesMessages.navNearby));
      expect(JamesMessages.forTabIndex(1), equals(JamesMessages.navClaim));
      expect(JamesMessages.forTabIndex(2), equals(JamesMessages.navScores));
      expect(JamesMessages.forTabIndex(3), equals(JamesMessages.navFriends));
      expect(JamesMessages.forTabIndex(4), equals(JamesMessages.navHistory));
    });

    test('forTabIndex returns null for out-of-range index', () {
      expect(JamesMessages.forTabIndex(-1), isNull);
      expect(JamesMessages.forTabIndex(5), isNull);
      expect(JamesMessages.forTabIndex(99), isNull);
    });

    test('navHistory has non-empty key and resolves to a non-empty string', () {
      expect(JamesMessages.navHistory.key, isNotEmpty);
      expect(JamesMessages.navHistory.resolve(), isNotEmpty);
    });

    test('dynamic nearbyFound includes count and box word', () {
      final msg = JamesMessages.nearbyFound(3, 'postboxes');
      expect(msg, contains('3'));
      expect(msg, contains('postboxes'));
    });

    test('dynamic claimSuccessMulti includes count and points', () {
      final msg = JamesMessages.claimSuccessMulti(2, 8);
      expect(msg, contains('2'));
      expect(msg, contains('8'));
    });

    test('idle pool has at least 5 variants for variety', () {
      // Sampling: resolve 50 times and collect unique messages.
      // The idle pool has 14 variants; 50 samples should surface at least 5.
      final seen = <String>{};
      for (var i = 0; i < 50; i++) {
        seen.add(JamesMessages.idle.resolve());
      }
      expect(seen.length, greaterThanOrEqualTo(5),
          reason: 'idle pool should have at least 5 distinct variants');
    });
  });

  // ---------------------------------------------------------------------------
  // ClaimHistoryScreen tests
  // ---------------------------------------------------------------------------

  group('ClaimHistoryEntry.fromJson', () {
    test('parses all fields from a full payload', () {
      final entry = ClaimHistoryEntry.fromJson({
        'postboxId': 'osm_12345',
        'lat': 51.5,
        'lng': -0.1,
        'monarch': 'EIIR',
        'reference': 'SW1A 1AA',
        'timesClaimed': 3,
        'firstClaimed': '2026-04-10',
        'lastClaimed': '2026-04-15',
        'totalPoints': 6,
      });
      expect(entry.postboxId, equals('osm_12345'));
      expect(entry.lat, equals(51.5));
      expect(entry.lng, equals(-0.1));
      expect(entry.monarch, equals('EIIR'));
      expect(entry.reference, equals('SW1A 1AA'));
      expect(entry.timesClaimed, equals(3));
      expect(entry.firstClaimed, equals('2026-04-10'));
      expect(entry.lastClaimed, equals('2026-04-15'));
      expect(entry.totalPoints, equals(6));
    });

    test('tolerates missing optional fields', () {
      final entry = ClaimHistoryEntry.fromJson({
        'postboxId': 'osm_1',
        'lat': 50.0,
        'lng': -1.0,
      });
      expect(entry.monarch, isNull);
      expect(entry.reference, isNull);
      expect(entry.timesClaimed, equals(1));
      expect(entry.totalPoints, equals(0));
      expect(entry.firstClaimed, isEmpty);
    });

    test('coerces numeric fields stored as double', () {
      final entry = ClaimHistoryEntry.fromJson({
        'postboxId': 'osm_2',
        'lat': 50.0,
        'lng': -1.0,
        'timesClaimed': 2.0,
        'totalPoints': 14.0,
      });
      expect(entry.timesClaimed, equals(2));
      expect(entry.timesClaimed, isA<int>());
      expect(entry.totalPoints, equals(14));
    });
  });

  group('ClaimHistoryScreen', () {
    testWidgets('renders all four period tabs', (tester) async {
      // The per-tab FutureBuilder will remain in the loading state because
      // FirebaseFunctions is not mocked — this smoke test just asserts the
      // tab bar itself builds cleanly.
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ClaimHistoryScreen()),
        ),
      );
      await tester.pump();
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('This week'), findsOneWidget);
      expect(find.text('This month'), findsOneWidget);
      expect(find.text('Lifetime'), findsOneWidget);
    });
  });

  group('UserProfilePage', () {
    testWidgets('renders display name and stat tiles without crashing',
        (tester) async {
      // UserProfilePage uses FirebaseFirestore.instance and FirebaseAuth.instance
      // which are mocked by setupFirebaseMocks(). The FutureBuilder will remain
      // in loading state — this test just verifies the widget tree builds cleanly.
      await tester.pumpWidget(
        const MaterialApp(
          home: UserProfilePage(uid: 'test-uid-123'),
        ),
      );
      await tester.pump();
      // AppBar should render with one of the two title strings.
      expect(
        find.textContaining('Profile'),
        findsOneWidget,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // SettingsScreen notification prefs tests
  // ---------------------------------------------------------------------------

  group('SettingsScreen notification prefs', () {
    Widget buildSettings() {
      final repo = UserRepository(
        firebaseAuth: MockFirebaseAuth(),
        firestore: FakeFirebaseFirestore(),
      );
      return MaterialApp(
        home: BlocProvider<AuthenticationBloc>(
          create: (_) => AuthenticationBloc(userRepository: repo),
          child: const SettingsScreen(),
        ),
      );
    }

    testWidgets('Notifications section header is visible', (tester) async {
      await tester.pumpWidget(buildSettings());
      // Allow initState async calls (_loadPrefs, _loadNotifPrefs) to complete.
      // No real user is signed in, so _loadNotifPrefs resolves immediately.
      await tester.pump();
      expect(find.text('Notifications', skipOffstage: false), findsOneWidget);
    });

    testWidgets('Three notification toggle titles appear after prefs load',
        (tester) async {
      // Use a tall viewport so the ListView builds all children eagerly —
      // ListView is lazy and only builds items in the visible area.
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(buildSettings());
      await tester.pump();
      expect(find.text('First friend to score today'), findsOneWidget);
      expect(find.text('Friend overtakes you'), findsOneWidget);
      expect(find.text('Added as a friend'), findsOneWidget);
    });
  });
}
