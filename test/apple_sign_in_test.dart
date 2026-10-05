import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/login/bloc/bloc.dart';
import 'package:postbox_game/user_repository.dart';

/// Apple-linked user whose re-authentication either throws [reauthError] or
/// succeeds with an Apple [authorizationCode] (what FlutterFire's iOS plugin
/// returns from the native sheet).
// ignore: must_be_immutable — test double records whether delete() ran.
class _AppleUser extends MockUser {
  _AppleUser({this.reauthError, this.authorizationCode})
      : super(uid: 'a1', email: 'relay@privaterelay.appleid.com');

  final FirebaseAuthException? reauthError;
  final String? authorizationCode;
  bool deleted = false;

  final reauthVia = <String>[];

  @override
  Future<UserCredential> reauthenticateWithProvider(
      AuthProvider provider) async {
    reauthVia.add('provider');
    if (reauthError != null) throw reauthError!;
    return _ReauthCredential(authorizationCode);
  }

  @override
  Future<UserCredential> reauthenticateWithPopup(AuthProvider provider) async {
    reauthVia.add('popup');
    if (reauthError != null) throw reauthError!;
    return _ReauthCredential(authorizationCode);
  }

  @override
  Future<void> delete() async => deleted = true;
}

class _ReauthCredential extends Fake implements UserCredential {
  _ReauthCredential(this.code);
  final String? code;

  @override
  AdditionalUserInfo? get additionalUserInfo =>
      AdditionalUserInfo(isNewUser: false, authorizationCode: code);
}

/// Records the revoked code, then fails, as it does when the Firebase Apple
/// provider has no OAuth code-flow key configured.
class _RevokeFailingAuth extends MockFirebaseAuth {
  _RevokeFailingAuth(MockUser user) : super(signedIn: true, mockUser: user);
  final revoked = <String>[];

  @override
  Future<void> revokeTokenWithAuthorizationCode(String code) async {
    revoked.add(code);
    throw FirebaseAuthException(code: 'invalid-credential');
  }
}

/// Fails every provider sign-in with [code], as the native Apple sheet does.
class _ThrowingProviderAuth extends MockFirebaseAuth {
  _ThrowingProviderAuth(this.code);
  final String code;

  @override
  Future<UserCredential> signInWithProvider(AuthProvider provider) async =>
      throw FirebaseAuthException(code: code);
}

/// Records which provider each web popup sign-in used; fails with [code] if set.
class _PopupAuth extends MockFirebaseAuth {
  _PopupAuth({this.code}) : super(mockUser: MockUser(uid: 'w1'));
  final String? code;
  final popups = <String>[];

  @override
  Future<UserCredential> signInWithPopup(AuthProvider provider) {
    popups.add(provider.providerId);
    if (code != null) throw FirebaseAuthException(code: code!);
    return super.signInWithPopup(provider);
  }

  @override
  Future<UserCredential> signInWithProvider(AuthProvider provider) =>
      throw StateError('web must use the popup flow');
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  test('isProviderSignInCancelled matches only cancellation codes', () {
    for (final code in [
      'canceled',
      'web-context-canceled',
      'popup-closed-by-user',
      'cancelled-popup-request',
    ]) {
      expect(
          isProviderSignInCancelled(FirebaseAuthException(code: code)), isTrue,
          reason: code);
    }
    // 'failed' / 'unknown' are real failures the user should hear about.
    for (final code in ['failed', 'unknown', 'invalid-credential']) {
      expect(
          isProviderSignInCancelled(FirebaseAuthException(code: code)), isFalse,
          reason: code);
    }
  });

  test('appleAuthProvider asks for name and email', () {
    final provider = appleAuthProvider();
    expect(provider.providerId, 'apple.com');
    expect(provider.scopes, containsAll(['email', 'name']));
  });

  group('signInWithApple', () {
    test('returns the signed-in user', () async {
      final auth = MockFirebaseAuth(mockUser: MockUser(uid: 'a1'));
      final repo = UserRepository(
          firebaseAuth: auth, firestore: FakeFirebaseFirestore());
      final user = await repo.signInWithApple();
      expect(user?.uid, 'a1');
    });

    test('returns null when the user dismisses the Apple sheet', () async {
      final auth = _ThrowingProviderAuth('canceled');
      final repo = UserRepository(
          firebaseAuth: auth, firestore: FakeFirebaseFirestore());
      expect(await repo.signInWithApple(), isNull);
    });

    test('rethrows a real failure', () async {
      final auth = _ThrowingProviderAuth('failed');
      final repo = UserRepository(
          firebaseAuth: auth, firestore: FakeFirebaseFirestore());
      await expectLater(
          repo.signInWithApple(),
          throwsA(isA<FirebaseAuthException>()
              .having((e) => e.code, 'code', 'failed')));
    });
  });

  group('LoginBloc Apple sign-in', () {
    Future<List<LoginState>> run(MockFirebaseAuth auth) async {
      final bloc = LoginBloc(
          userRepository: UserRepository(
              firebaseAuth: auth, firestore: FakeFirebaseFirestore()));
      final states = <LoginState>[];
      final sub = bloc.stream.listen(states.add);
      bloc.add(LoginWithApplePressed());
      await Future<void>.delayed(Duration.zero);
      await bloc.close();
      await sub.cancel();
      return states;
    }

    test('returns to idle, not failure, when cancelled', () async {
      final auth = _ThrowingProviderAuth('canceled');
      final states = await run(auth);
      expect(states.last.isFailure, isFalse);
      expect(states.last.isSubmitting, isFalse);
    });

    test('reports a real failure', () async {
      final auth = _ThrowingProviderAuth('network-request-failed');
      final states = await run(auth);
      expect(states.last.isFailure, isTrue);
      expect(states.last.errorMessage, 'No internet connection.');
    });
  });

  group('deleteAccount for an Apple user', () {
    test('returns false, deleting nothing, when re-auth is cancelled',
        () async {
      final user =
          _AppleUser(reauthError: FirebaseAuthException(code: 'canceled'));
      await user.linkWithProvider(AppleAuthProvider());
      final repo = UserRepository(
          firebaseAuth: MockFirebaseAuth(signedIn: true, mockUser: user),
          firestore: FakeFirebaseFirestore());
      expect(await repo.deleteAccount(), isFalse);
      expect(user.deleted, isFalse);
    });

    test('throws a real re-auth failure', () async {
      final user =
          _AppleUser(reauthError: FirebaseAuthException(code: 'failed'));
      await user.linkWithProvider(AppleAuthProvider());
      final repo = UserRepository(
          firebaseAuth: MockFirebaseAuth(signedIn: true, mockUser: user),
          firestore: FakeFirebaseFirestore());
      await expectLater(
          repo.deleteAccount(), throwsA(isA<FirebaseAuthException>()));
      expect(user.deleted, isFalse);
    });

    test('revokes the Apple token, and still deletes if revocation fails',
        () async {
      final user = _AppleUser(authorizationCode: 'apple-code');
      await user.linkWithProvider(AppleAuthProvider());
      final auth = _RevokeFailingAuth(user);
      final repo = UserRepository(
          firebaseAuth: auth, firestore: FakeFirebaseFirestore());
      expect(await repo.deleteAccount(), isTrue);
      expect(auth.revoked, ['apple-code']);
      expect(user.deleted, isTrue);
    });
  });

  group('web (popup flow)', () {
    test('Google and Apple sign in through Firebase popups', () async {
      final auth = _PopupAuth();
      final repo = UserRepository(
          firebaseAuth: auth, firestore: FakeFirebaseFirestore(), isWeb: true);
      expect((await repo.signInWithGoogle())?.uid, 'w1');
      expect((await repo.signInWithApple())?.uid, 'w1');
      expect(auth.popups, ['google.com', 'apple.com']);
    });

    test('closing the popup returns null, not an error', () async {
      final repo = UserRepository(
          firebaseAuth: _PopupAuth(code: 'popup-closed-by-user'),
          firestore: FakeFirebaseFirestore(),
          isWeb: true);
      expect(await repo.signInWithGoogle(), isNull);
      expect(await repo.signInWithApple(), isNull);
    });

    test('a blocked popup is a real failure', () async {
      final repo = UserRepository(
          firebaseAuth: _PopupAuth(code: 'popup-blocked'),
          firestore: FakeFirebaseFirestore(),
          isWeb: true);
      await expectLater(
          repo.signInWithApple(), throwsA(isA<FirebaseAuthException>()));
    });

    test('deleting an Apple account re-authenticates with a popup', () async {
      final user = _AppleUser();
      await user.linkWithProvider(AppleAuthProvider());
      final repo = UserRepository(
          firebaseAuth: MockFirebaseAuth(signedIn: true, mockUser: user),
          firestore: FakeFirebaseFirestore(),
          isWeb: true);
      expect(await repo.deleteAccount(), isTrue);
      expect(user.reauthVia, ['popup']);
      expect(user.deleted, isTrue);
    });

    test('closing the Apple re-auth popup deletes nothing', () async {
      final user = _AppleUser(
          reauthError: FirebaseAuthException(code: 'popup-closed-by-user'));
      await user.linkWithProvider(AppleAuthProvider());
      final repo = UserRepository(
          firebaseAuth: MockFirebaseAuth(signedIn: true, mockUser: user),
          firestore: FakeFirebaseFirestore(),
          isWeb: true);
      expect(await repo.deleteAccount(), isFalse);
      expect(user.deleted, isFalse);
    });
  });
}
