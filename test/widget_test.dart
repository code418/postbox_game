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
import 'package:postbox_game/county_heatmap.dart';
import 'package:postbox_game/display_name_utils.dart';
import 'package:postbox_game/friends_screen.dart';
import 'package:postbox_game/fuzzy_compass.dart';
import 'package:postbox_game/location_service.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/london_date.dart';
import 'package:postbox_game/main.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/settings_screen.dart';
import 'package:postbox_game/streak_service.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/user_profile_page.dart';
import 'package:postbox_game/user_repository.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/nearby.dart';
import 'package:postbox_game/route/destination_picker_screen.dart';
import 'package:postbox_game/reports/report_repository.dart';
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

  group('isWidgetClaimDeepLink (Kotlin DEEP_LINK contract)', () {
    // Mirror of PostboxWidgetProvider.kt:74
    //   private const val DEEP_LINK = "postbox://claim?source=widget"
    // Pin the Dart-side parser against the exact Kotlin URI so a future
    // rename of either side fails this test before users see "the widget
    // tap does nothing".
    test('accepts the exact Kotlin DEEP_LINK URI', () {
      expect(
        isWidgetClaimDeepLink(Uri.parse('postbox://claim?source=widget')),
        isTrue,
      );
    });
    test('rejects a null URI', () {
      expect(isWidgetClaimDeepLink(null), isFalse);
    });
    test('rejects a different host', () {
      // e.g. a hypothetical "postbox://home?source=widget" — Dart would
      // treat that as a different deep link.
      expect(
        isWidgetClaimDeepLink(Uri.parse('postbox://home?source=widget')),
        isFalse,
      );
    });
    test('rejects a missing source param', () {
      // Bare postbox://claim with no source=widget shouldn't trigger the
      // auto-scan path — defends against an unrelated future deep link
      // that happens to share the "claim" host but a different source.
      expect(
        isWidgetClaimDeepLink(Uri.parse('postbox://claim')),
        isFalse,
      );
    });
    test('rejects a different source value', () {
      expect(
        isWidgetClaimDeepLink(Uri.parse('postbox://claim?source=push')),
        isFalse,
      );
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

      test('min/max constants match the server contract', () {
        // updateDisplayName.ts rejects len < 2 and len > 30. Pin both ends
        // so a future client-side bump can't get out of step with the
        // server's parseSuggestedMonarch / sanitiseName branches.
        expect(Validators.minDisplayNameChars, equals(2));
        expect(Validators.maxDisplayNameChars, equals(30));
      });

      test('minPasswordChars matches Firebase Auth minimum (6)', () {
        // Firebase Auth's createUserWithEmailAndPassword rejects shorter
        // passwords with weak-password. The client-side check mirrors it
        // so users see the rule at input time. Pinning catches accidental
        // drift either tighter (would fail Firebase rejects we don't pre-
        // empt) or looser (would lose UX guard before submission).
        expect(Validators.minPasswordChars, equals(6));
      });

      // Scunthorpe-problem regression: the comment in lib/validators.dart
      // explicitly lists names that an older block list rejected (arse, cock,
      // dick, mong, spic). Pin those legitimate names so a tightening change
      // can't silently break real users. Keep in sync with the equivalent
      // backend regression in functions/src/test/test.index.ts (containsProfanity).
      test('allows legitimate names that an old block list would have rejected',
          () {
        expect(Validators.isValidDisplayName('Richard'), isTrue);
        expect(Validators.isValidDisplayName('Dickson'), isTrue);
        expect(Validators.isValidDisplayName('Cockburn'), isTrue);
        expect(Validators.isValidDisplayName('Hancock'), isTrue);
        expect(Validators.isValidDisplayName('Peacock'), isTrue);
        expect(Validators.isValidDisplayName('Arsenal'), isTrue);
        expect(Validators.isValidDisplayName('Mongolia'), isTrue);
        expect(Validators.isValidDisplayName('among'), isTrue);
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
  // freshStreak pure helper — shared between StreakService + HomeWidgetService
  // ---------------------------------------------------------------------------

  group('freshStreak', () {
    // The helper is the single source of truth for "is this user's streak
    // still alive". HomeWidgetService and StreakService both call it so a
    // future tweak (e.g. counting "today only" instead of "today or yesterday"
    // as fresh) doesn't have to be applied in two places.
    test('returns null when storedStreak is null', () {
      expect(
        freshStreak(
          storedStreak: null,
          lastClaimDate: '2026-05-18',
          today: '2026-05-18',
          yesterday: '2026-05-17',
        ),
        isNull,
      );
    });

    test('returns 0 when storedStreak is 0 (no-op)', () {
      expect(
        freshStreak(
          storedStreak: 0,
          lastClaimDate: '2026-05-18',
          today: '2026-05-18',
          yesterday: '2026-05-17',
        ),
        equals(0),
      );
    });

    test('returns stored value when last claim was today', () {
      expect(
        freshStreak(
          storedStreak: 7,
          lastClaimDate: '2026-05-18',
          today: '2026-05-18',
          yesterday: '2026-05-17',
        ),
        equals(7),
      );
    });

    test('returns stored value when last claim was yesterday', () {
      expect(
        freshStreak(
          storedStreak: 4,
          lastClaimDate: '2026-05-17',
          today: '2026-05-18',
          yesterday: '2026-05-17',
        ),
        equals(4),
      );
    });

    test('returns 0 when last claim was two days ago', () {
      expect(
        freshStreak(
          storedStreak: 9,
          lastClaimDate: '2026-05-16',
          today: '2026-05-18',
          yesterday: '2026-05-17',
        ),
        equals(0),
      );
    });

    test('returns 0 when lastClaimDate is missing', () {
      expect(
        freshStreak(
          storedStreak: 5,
          lastClaimDate: null,
          today: '2026-05-18',
          yesterday: '2026-05-17',
        ),
        equals(0),
      );
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

    // formatRouteDistance — metric-only auto-switch between m and km. Used
    // by RoutePreviewScreen and LiveRouteScreen so the user sees "800 m"
    // for a short route instead of "0.80 km".
    test('formatRouteDistance shows metres under 1 km', () {
      expect(AppPreferences.formatRouteDistance(0), equals('0 m'));
      expect(AppPreferences.formatRouteDistance(500), equals('500 m'));
      expect(AppPreferences.formatRouteDistance(999.4), equals('999 m'));
    });

    test('formatRouteDistance shows km at and above 1 km', () {
      expect(AppPreferences.formatRouteDistance(1000), equals('1.00 km'));
      expect(AppPreferences.formatRouteDistance(1234), equals('1.23 km'));
      expect(AppPreferences.formatRouteDistance(30000), equals('30.00 km'));
    });

    test('formatRouteDistance returns "..." for infinity', () {
      expect(AppPreferences.formatRouteDistance(double.infinity), equals('...'));
    });

    test('formatRouteDistance returns "..." for NaN', () {
      expect(AppPreferences.formatRouteDistance(double.nan), equals('...'));
    });
  });

  group('AppPreferences constants (cross-platform contract)', () {
    test('claimRadiusMeters is 30.0 — must match functions/src/startScoring.ts CLAIM_RADIUS_METERS', () {
      // The claim cooldown radius is shared with the backend's startScoring
      // callable. If the values drift, the client thinks a box is claimable
      // while the server rejects it (or vice versa). Pin the Dart side here;
      // the TS side's startScoring.ts has a comment pointing back at this
      // const. Bumping either requires bumping the other.
      expect(AppPreferences.claimRadiusMeters, equals(30.0));
    });

    test('nearbyRadiusMeters is 540.0 — well under the 2000m server clamp', () {
      // Server clamps any incoming meters to 2000 in nearbyPostboxes.
      // The nearby scan should stay well under that so we don't silently
      // get clipped if the client ever asks for a larger radius.
      expect(AppPreferences.nearbyRadiusMeters, equals(540.0));
      expect(AppPreferences.nearbyRadiusMeters, lessThan(2000));
    });
  });

  group('ReportRepository constants (cross-platform contract)', () {
    test('maxPhotos is 3 — must match functions/src/reports.ts MAX_PHOTOS', () {
      // The photo cap is enforced both client-side (when picking) and server-
      // side (in parsePhotos). If they drift the client could upload 4 photos
      // only for the server to reject the whole report. The TS side pins this
      // via the "accepts exactly 3 photos" and "rejects more than 3" tests.
      expect(ReportRepository.maxPhotos, equals(3));
    });

    test('maxPhotoBytes is 10 MB — must match storage.rules size limit', () {
      // storage.rules has `request.resource.size < 10 * 1024 * 1024` for the
      // report_photos path. If the client allowed larger uploads, Storage
      // would reject them at upload time (after the user already picked the
      // photo) — frustrating UX. The client-side cap should match the rule.
      expect(ReportRepository.maxPhotoBytes, equals(10 * 1024 * 1024));
    });

    test('maxNoteChars is 280 — must match functions/src/reports.ts NOTE_MAX',
        () {
      // submitReport rejects notes longer than NOTE_MAX. The TextField's
      // maxLength uses this constant so the UI can't get out of step. A
      // drift here means users see "your note is too long" only AFTER
      // submission instead of being stopped at the input field.
      expect(ReportRepository.maxNoteChars, equals(280));
    });

    test('maxReferenceChars is 40 — must match functions/src/reports.ts REFERENCE_MAX',
        () {
      // Same drift hazard as maxNoteChars: TextField maxLength must match
      // what parseReference will accept server-side.
      expect(ReportRepository.maxReferenceChars, equals(40));
    });
  });

  group('initialsFor', () {
    // Shared by friends list avatars and the UserProfilePage header. Pinning
    // the rules so a future tweak to one screen's avatar doesn't drift the
    // other.
    test('returns ? for an empty string', () {
      expect(initialsFor(''), equals('?'));
    });

    test('returns ? for whitespace-only', () {
      expect(initialsFor('   '), equals('?'));
    });

    test('first letters of first two words for multi-word names', () {
      expect(initialsFor('John Doe'), equals('JD'));
      expect(initialsFor('alice bob carol'), equals('AB'));
    });

    test('first two letters for a single-word name', () {
      expect(initialsFor('Alice'), equals('AL'));
      expect(initialsFor('postie'), equals('PO'));
    });

    test('single-letter name returns just that letter', () {
      expect(initialsFor('Z'), equals('Z'));
    });

    test('collapses internal multiple spaces', () {
      // "John   Doe" splits with empty parts which are filtered out, so the
      // first two non-empty words still drive the result.
      expect(initialsFor('John   Doe'), equals('JD'));
    });
  });

  group('LocationServiceException', () {
    // Previously callers ran `e.toString().contains('permanently denied')`
    // across 4 files. The kind enum is the typed dispatch target; these tests
    // pin the contract so a future message rewording can't silently break the
    // SnackBar/James dispatch in any caller.
    test('exposes the kind for switch-based dispatch', () {
      const e = LocationServiceException(
        LocationErrorKind.permissionPermanentlyDenied,
        'irrelevant',
      );
      expect(e.kind, equals(LocationErrorKind.permissionPermanentlyDenied));
    });

    test('preserves the human-readable message for SnackBar display', () {
      const msg = 'Location services are disabled.';
      const e = LocationServiceException(
        LocationErrorKind.servicesDisabled,
        msg,
      );
      expect(e.message, equals(msg));
    });

    test('toString includes the kind name so logs are diagnosable', () {
      const e = LocationServiceException(
        LocationErrorKind.permissionDenied,
        'Location permission denied.',
      );
      expect(e.toString(), contains('permissionDenied'));
      expect(e.toString(), contains('Location permission denied.'));
    });

    test('has all three kinds we dispatch on in callers', () {
      // Callers (claim.dart, nearby.dart, claim_quiz_sheet.dart,
      // destination_picker_screen.dart) use exhaustive switch on this enum —
      // adding a kind here without updating callers is an analyzer error.
      // Pin the set so renames/removals trigger a test failure too.
      expect(LocationErrorKind.values.toSet(), equals({
        LocationErrorKind.servicesDisabled,
        LocationErrorKind.permissionDenied,
        LocationErrorKind.permissionPermanentlyDenied,
      }));
    });
  });

  group('FriendsScreen constants (cross-platform contract)', () {
    test('maxFriends is 200 — must match firestore.rules friends.size() cap',
        () {
      // firestore.rules has `request.resource.data.friends.size() <= 200` on
      // the users doc update. The client-side check at FriendsScreen.maxFriends
      // is a pre-flight check so the user sees a friendly error before the
      // write is rejected by the rules engine. Drift means the client thinks
      // the list isn't full but Firestore refuses the write with a
      // permission-denied error.
      expect(FriendsScreen.maxFriends, equals(200));
    });
  });

  // ---------------------------------------------------------------------------
  // FuzzyCompass unit tests
  // ---------------------------------------------------------------------------

  group('mapColourFor', () {
    test('chosen palette key wins over self default', () {
      final c = mapColourFor(uid: 'abc', isSelf: true, chosenKey: 'teal');
      expect(c, equals(kMapColourPalette['teal']));
    });

    test('self with no chosen key falls back to postal red', () {
      final c = mapColourFor(uid: 'abc', isSelf: true);
      expect(c, equals(postalRed));
    });

    test('friend with no chosen key uses deterministic auto palette', () {
      final c1 = mapColourFor(uid: 'friend-uid', isSelf: false);
      final c2 = mapColourFor(uid: 'friend-uid', isSelf: false);
      expect(c1, equals(c2));
      expect(kMapColourPalette.values.contains(c1), isTrue);
    });

    test('unknown chosen key falls back to auto palette', () {
      final auto = mapColourFor(uid: 'x', isSelf: false);
      final fallback = mapColourFor(uid: 'x', isSelf: false, chosenKey: 'no_such_colour');
      expect(fallback, equals(auto));
    });

    test('different uids generally yield different auto colours', () {
      final colours = <Color>{
        for (final uid in ['a1', 'b2', 'c3', 'd4', 'e5'])
          mapColourFor(uid: uid, isSelf: false),
      };
      // Not all 5 are guaranteed unique, but at least 2 distinct values is
      // a meaningful sanity check on the hash distribution.
      expect(colours.length, greaterThan(1));
    });
  });

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

    test('rareCiphers and historicCiphers are disjoint', () {
      // postbox_marker.dart renders the rare-star and historic-"H" badges in
      // the same top-right slot. They're guarded by separate `if` conditions
      // so a cipher placed in both sets would render two stacked badges over
      // each other. Pin that the sets share no members so the UI invariant
      // (at most one badge per pin) holds.
      final overlap = MonarchInfo.rareCiphers
          .intersection(MonarchInfo.historicCiphers);
      expect(overlap, isEmpty,
          reason: 'Cipher(s) in both rareCiphers and historicCiphers: $overlap');
    });

    test('rareCiphers and historicCiphers are all in "all"', () {
      // A cipher that is "rare" or "historic" but not in `all` would never
      // render the badge — postboxMarker only ever sees ciphers that came
      // from the server (which whitelists against KNOWN_MONARCHS, matching
      // `all`). A typo in either set would silently disable the badge.
      for (final c in MonarchInfo.rareCiphers) {
        expect(MonarchInfo.all.contains(c), isTrue,
            reason: 'rareCipher $c is not in MonarchInfo.all');
      }
      for (final c in MonarchInfo.historicCiphers) {
        expect(MonarchInfo.all.contains(c), isTrue,
            reason: 'historicCipher $c is not in MonarchInfo.all');
      }
    });

    test('"all" exactly matches the cross-platform contract', () {
      // Pin the exact set so adding or removing a monarch on the Dart side
      // breaks this test loudly. The TS side has a mirror test against
      // KNOWN_MONARCHS — both must match this same set to be cross-platform
      // consistent (a new monarch added to one side without the other would
      // mean the quiz pool / backend whitelist drift apart). Order-independent.
      final sorted = [...MonarchInfo.all]..sort();
      expect(
        sorted,
        equals(<String>[
          'CIIIR', 'EIIR', 'EVIIIR', 'EVIIR', 'GR',
          'GVIR', 'GVR', 'SCOTTISH_CROWN', 'VR',
        ]),
      );
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
        JamesMessages.navCountyLeaders,
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
        JamesMessages.navCountyLeaders,
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
      // ListView.builder is lazy and only builds items in the visible area;
      // expand the viewport so the Notifications header (now below the new
      // Map section) is built before assertion.
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

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

  // ---------------------------------------------------------------------------
  // JamesMessages route-mode unit tests
  // ---------------------------------------------------------------------------

  group('JamesMessages route mode', () {
    test('routeStart resolves to a non-empty string', () {
      expect(JamesMessages.routeStart.resolve(), isNotEmpty);
    });

    test('routeStart pool has at least 4 variants', () {
      final seen = <String>{};
      for (var i = 0; i < 50; i++) {
        seen.add(JamesMessages.routeStart.resolve());
      }
      expect(seen.length, greaterThanOrEqualTo(4));
    });

    test('routePostboxNearby resolves to a non-empty string', () {
      expect(JamesMessages.routePostboxNearby.resolve(), isNotEmpty);
    });

    test('routePostboxNearby pool has at least 4 variants', () {
      final seen = <String>{};
      for (var i = 0; i < 50; i++) {
        seen.add(JamesMessages.routePostboxNearby.resolve());
      }
      expect(seen.length, greaterThanOrEqualTo(4));
    });

    test('routeHint("ahead") returns a non-empty string', () {
      expect(JamesMessages.routeHint('ahead'), isNotEmpty);
    });

    test('routeHint("left") returns a non-empty string', () {
      expect(JamesMessages.routeHint('left'), isNotEmpty);
    });

    test('routeHint("right") returns a non-empty string', () {
      expect(JamesMessages.routeHint('right'), isNotEmpty);
    });

    test('routeHint("behind") returns a non-empty string', () {
      expect(JamesMessages.routeHint('behind'), isNotEmpty);
    });

    test('routeHint with unknown direction falls back to ahead pool', () {
      // Should not throw; returns a non-empty string from the "ahead" pool.
      expect(JamesMessages.routeHint('diagonal'), isNotEmpty);
    });

    test('routeHint produces distinct lines for different directions', () {
      // Sample each direction many times and verify the pools are not identical.
      final aheadSamples = {for (var i = 0; i < 30; i++) JamesMessages.routeHint('ahead')};
      final leftSamples  = {for (var i = 0; i < 30; i++) JamesMessages.routeHint('left')};
      // The union of both sample sets should be larger than either alone (pools differ).
      expect(aheadSamples.union(leftSamples).length,
          greaterThan(aheadSamples.length));
    });

    test('routeArrival resolves to a non-empty string', () {
      expect(JamesMessages.routeArrival.resolve(), isNotEmpty);
    });

    test('routeArrival pool has at least 4 variants', () {
      final seen = <String>{};
      for (var i = 0; i < 50; i++) {
        seen.add(JamesMessages.routeArrival.resolve());
      }
      expect(seen.length, greaterThanOrEqualTo(4));
    });

    test('no route-mode message contains an em-dash', () {
      // House style: em-dashes are banned in James dialogue.
      const emDash = '—';
      for (var i = 0; i < 20; i++) {
        expect(JamesMessages.routeStart.resolve(), isNot(contains(emDash)));
        expect(JamesMessages.routePostboxNearby.resolve(), isNot(contains(emDash)));
        expect(JamesMessages.routeArrival.resolve(), isNot(contains(emDash)));
        for (final dir in ['ahead', 'left', 'right', 'behind']) {
          expect(JamesMessages.routeHint(dir), isNot(contains(emDash)));
        }
      }
    });
  });

  // ---------------------------------------------------------------------------
  // /route named-route smoke test
  // ---------------------------------------------------------------------------

  group('/route named route', () {
    testWidgets('resolves to DestinationPickerScreen when authenticated',
        (tester) async {
      // Build a minimal MaterialApp with the /route entry (same pattern as
      // main.dart). Inject initialPosition so the screen does not attempt a
      // real GPS fix (which would hang in a test environment).
      const testPosition = LatLng(51.5074, -0.1278);
      await tester.pumpWidget(
        MaterialApp(
          routes: {
            '/route': (_) => const DestinationPickerScreen(
                  initialPosition: testPosition,
                ),
          },
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => Navigator.pushNamed(ctx, '/route'),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      // pump once to process the push, then a second time for the route
      // animation frames.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(DestinationPickerScreen), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // Nearby "Walk to a destination" button test
  // ---------------------------------------------------------------------------

  group('Nearby route-mode entry button', () {
    testWidgets('tapping "Walk to a destination" pushes /route',
        (tester) async {
      // Use a NavigatorObserver spy to record pushNamed calls.
      final pushedRoutes = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [
            _RouteNameObserver(pushedRoutes),
          ],
          // Register /route so Navigator.pushNamed does not throw.
          routes: {
            '/route': (_) => const Scaffold(body: Text('route screen')),
          },
          home: const Scaffold(body: Nearby()),
        ),
      );
      // Nearby starts in the initial stage where the button is visible.
      await tester.pump();
      expect(find.text('Walk to a destination'), findsOneWidget);
      await tester.tap(find.text('Walk to a destination'));
      await tester.pumpAndSettle();
      expect(pushedRoutes, contains('/route'));
    });
  });
}

// ---------------------------------------------------------------------------
// Helper: NavigatorObserver spy
// ---------------------------------------------------------------------------

class _RouteNameObserver extends NavigatorObserver {
  _RouteNameObserver(this._pushedRoutes);

  final List<String> _pushedRoutes;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final name = route.settings.name;
    if (name != null) _pushedRoutes.add(name);
  }
}
