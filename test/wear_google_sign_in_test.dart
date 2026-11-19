// Google sign-in on the Wear OS watch.
//
// google_sign_in 7's `authenticate()` always runs Credential Manager's
// "button flow" (GetSignInWithGoogleOption). On Wear OS that flow never finds
// a credential: Crashlytics issue 5bca9fbc ("No credential available: No
// credentials available") had every one of its events on a watch (Pixel
// Watch 3/5, Wear emulators) and none on a phone, so every watch sign-in since
// the May 2026 move from google_sign_in 6 failed with "No Google account on
// this watch", accounts or not. Google's own Wear samples use GetGoogleIdOption,
// which is what `attemptLightweightAuthentication()` sends, so the watch signs
// in through that instead. These tests pin it.

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:postbox_game/services/crashlytics_helper.dart';
import 'package:postbox_game/user_repository.dart';

class _FakeAccount extends Fake implements GoogleSignInAccount {
  @override
  GoogleSignInAuthentication get authentication =>
      const GoogleSignInAuthentication(idToken: 'watch-id-token');
}

/// Answers the lightweight (GetGoogleIdOption) flow with [result] or [error],
/// and fails the test outright if anything reaches for the button flow.
class _WatchGoogleSignIn extends Fake implements GoogleSignIn {
  _WatchGoogleSignIn({this.result, this.error});

  final GoogleSignInAccount? result;
  final GoogleSignInException? error;
  final reportAllExceptionsArgs = <bool>[];

  @override
  Future<GoogleSignInAccount?>? attemptLightweightAuthentication({
    bool reportAllExceptions = false,
  }) async {
    reportAllExceptionsArgs.add(reportAllExceptions);
    if (error != null) throw error!;
    return result;
  }

  @override
  Future<GoogleSignInAccount> authenticate({
    List<String> scopeHint = const [],
  }) =>
      fail('the watch must not use the button flow (authenticate())');
}

class _FakeCrashlytics extends Fake implements FirebaseCrashlytics {
  final reasons = <Object?>[];

  @override
  Future<void> recordError(
    dynamic exception,
    StackTrace? stack, {
    dynamic reason,
    Iterable<Object> information = const [],
    bool? printDetails,
    bool fatal = false,
  }) async =>
      reasons.add(reason);
}

void main() {
  late _FakeCrashlytics crashlytics;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  setUp(() {
    CrashlyticsHelper.resetForTest();
    crashlytics = _FakeCrashlytics();
    CrashlyticsHelper.instance = crashlytics;
  });

  tearDown(CrashlyticsHelper.resetForTest);

  UserRepository repo(GoogleSignIn google, {MockFirebaseAuth? auth}) =>
      UserRepository(
        firebaseAuth: auth ?? MockFirebaseAuth(mockUser: MockUser(uid: 'w1')),
        googleSignin: google,
        firestore: FakeFirebaseFirestore(),
        isWeb: false,
      );

  test('signs in to Firebase with the account the watch offers', () async {
    final auth = MockFirebaseAuth(mockUser: MockUser(uid: 'w1'));
    final google = _WatchGoogleSignIn(result: _FakeAccount());

    final user = await repo(google, auth: auth).signInWithGoogleOnWatch();

    expect(user?.uid, 'w1');
    expect(auth.currentUser?.uid, 'w1');
    // A dismissed account sheet must throw `canceled` rather than resolve to
    // null, or it would read as "no Google account on this watch".
    expect(google.reportAllExceptionsArgs, [true]);
    expect(crashlytics.reasons, isEmpty);
  });

  test('no account offered is reported as no Google account on the watch',
      () async {
    final google = _WatchGoogleSignIn();

    await expectLater(
      repo(google).signInWithGoogleOnWatch(),
      throwsA(isA<GoogleSignInException>().having(
          isNoGoogleAccountOnDevice, 'isNoGoogleAccountOnDevice', isTrue)),
    );
    // Recorded so production shows whether real watches still hit this.
    expect(crashlytics.reasons, ['google_sign_in_wear:no_credential']);
  });

  test('backing out of the account sheet returns to idle', () async {
    for (final code in [
      GoogleSignInExceptionCode.canceled,
      GoogleSignInExceptionCode.interrupted,
    ]) {
      final google =
          _WatchGoogleSignIn(error: GoogleSignInException(code: code));
      expect(await repo(google).signInWithGoogleOnWatch(), isNull,
          reason: '$code');
    }
    expect(crashlytics.reasons, isEmpty);
  });

  test('other failures are recorded and rethrown', () async {
    final google = _WatchGoogleSignIn(
      error: const GoogleSignInException(
          code: GoogleSignInExceptionCode.providerConfigurationError),
    );

    await expectLater(
      repo(google).signInWithGoogleOnWatch(),
      throwsA(isA<GoogleSignInException>().having((e) => e.code, 'code',
          GoogleSignInExceptionCode.providerConfigurationError)),
    );
    expect(crashlytics.reasons, [
      'google_sign_in_wear:${GoogleSignInExceptionCode.providerConfigurationError}'
    ]);
  });
}
