import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:postbox_game/firebase_functions_eu.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:postbox_game/maintenance_guard.dart';
import 'package:postbox_game/services/claim_outbox.dart';
import 'package:postbox_game/services/crashlytics_helper.dart';
import 'package:postbox_game/validators.dart';

/// The description prefix `google_sign_in_android` puts on a Credential
/// Manager `NoCredentialException` before collapsing it into the catch-all
/// [GoogleSignInExceptionCode.unknownError].
///
/// Source: `google_sign_in_android/lib/google_sign_in_android.dart`,
/// `_authenticate`, `case GetCredentialFailureType.noCredential` (checked
/// against 7.2.15). The plugin exposes no distinct code for it, so the
/// description is the only signal. `noGoogleAccountPrefixIsCurrent` in
/// `test/google_signin_failure_test.dart` re-reads the resolved plugin source
/// so a version bump that changes the wording fails a test rather than
/// silently reverting users to the unhelpful generic message.
const String kNoGoogleCredentialPrefix = 'No credential available';

/// True when a Google sign-in failed because the DEVICE has no Google account
/// to offer, rather than because anything went wrong.
///
/// Worth its own message: the generic "Sign in failed. Please try again."
/// tells the user to do the one thing that cannot work, and Crashlytics showed
/// exactly that — 86 non-fatals from 5 users over 13 sessions, i.e. ~17
/// hopeless retries each.
bool isNoGoogleAccountOnDevice(GoogleSignInException e) =>
    e.code == GoogleSignInExceptionCode.unknownError &&
    (e.description ?? '').startsWith(kNoGoogleCredentialPrefix);

/// Advice for a Google sign-in failure, or null when there is none specific
/// and the caller should use its own generic wording.
String? googleSignInFailureMessage(GoogleSignInException e) {
  if (isNoGoogleAccountOnDevice(e)) {
    return 'No Google account on this device. Add one in your device '
        'settings, or sign in with an email address.';
  }
  return switch (e.code) {
    GoogleSignInExceptionCode.providerConfigurationError ||
    GoogleSignInExceptionCode.clientConfigurationError =>
      'Google sign-in is unavailable on this device. Try an email address.',
    GoogleSignInExceptionCode.uiUnavailable =>
      'Could not open the Google sign-in prompt. Please try again.',
    _ => null,
  };
}

/// True when a Firebase provider sign-in (Apple anywhere, Google on the web)
/// failed only because the user backed out: the native Apple sheet on iOS
/// (`canceled`), the Custom Tab on Android (`web-context-canceled`), or the
/// browser popup on the web (`popup-closed-by-user`, `cancelled-popup-request`).
/// Like a cancelled Google chooser, that is not an error and must not show
/// "Sign in failed".
bool isProviderSignInCancelled(FirebaseAuthException e) => const {
      'canceled',
      'web-context-canceled',
      'web-context-cancelled',
      'popup-closed-by-user',
      'cancelled-popup-request',
    }.contains(e.code);

/// The Firebase provider for Sign in with Apple, asking for the name and email
/// scopes. Apple only returns them on the user's FIRST authorisation, so the
/// request must be made every time.
AppleAuthProvider appleAuthProvider() => AppleAuthProvider()
  ..addScope('email')
  ..addScope('name');

class UserRepository {
  final FirebaseAuth _firebaseAuth;
  final GoogleSignIn _googleSignIn;
  final FirebaseFirestore _firestore;

  /// Web uses Firebase's popup flow for Google and Apple: google_sign_in 7
  /// cannot `authenticate()` on the web (it only renders its own button), and
  /// a popup keeps both providers on one code path. Injectable for tests.
  final bool _isWeb;

  UserRepository(
      {FirebaseAuth? firebaseAuth,
      GoogleSignIn? googleSignin,
      FirebaseFirestore? firestore,
      bool? isWeb})
      : _firebaseAuth = firebaseAuth ?? FirebaseAuth.instance,
        _googleSignIn = googleSignin ?? GoogleSignIn.instance,
        _firestore = firestore ?? FirebaseFirestore.instance,
        _isWeb = isWeb ?? kIsWeb;

  /// Signs in with a Firebase OAuth [provider] in a browser popup (web only).
  /// Returns null when the user closes the popup.
  Future<User?> _signInWithPopup(AuthProvider provider, String label) async {
    try {
      return (await _firebaseAuth.signInWithPopup(provider)).user;
    } on FirebaseAuthException catch (e) {
      if (isProviderSignInCancelled(e)) return null;
      CrashlyticsHelper.recordHandled(e, StackTrace.current,
          reason: '${label}_sign_in:${e.code}',
          dedupeKey: '${label}_sign_in:${e.code}');
      rethrow;
    }
  }

  Future<User?> signInWithGoogle() async {
    if (_isWeb) return _signInWithPopup(GoogleAuthProvider(), 'google');
    final GoogleSignInAccount googleUser;
    try {
      googleUser = await _googleSignIn.authenticate();
    } on GoogleSignInException catch (e) {
      // canceled  : user dismissed the chooser. interrupted: dialog closed
      // mid-flow (e.g. user navigated away). The plugin classifies both as
      // "no real error" — return null so the UI returns to its idle state
      // instead of flashing a "Sign in failed" snack.
      if (e.code == GoogleSignInExceptionCode.canceled ||
          e.code == GoogleSignInExceptionCode.interrupted) {
        return null;
      }
      // A genuine (non-cancellation) Google sign-in failure — record it before
      // it propagates to the login UI. Deduped per code: a user with no Google
      // account on the device retries until they give up, and 17 identical
      // non-fatals per session tell us nothing the first one didn't.
      CrashlyticsHelper.recordHandled(e, StackTrace.current,
          reason: 'google_sign_in:${e.code}',
          dedupeKey: 'google_sign_in:${e.code}');
      rethrow;
    }
    final GoogleSignInAuthentication googleAuth = googleUser.authentication;
    final AuthCredential credential = GoogleAuthProvider.credential(
      idToken: googleAuth.idToken,
    );
    final userCredential = await _firebaseAuth.signInWithCredential(credential);
    // The onUserCreated Cloud Function creates the Firestore profile
    // (displayName, createdAt) when a new Auth user is first created.
    // No client-side Firestore write is needed here.
    return userCredential.user;
  }

  /// Signs in with Apple through Firebase, with no extra plugin: the native
  /// sheet (`ASAuthorizationController`) on iOS, a Custom Tab web flow on
  /// Android, and a popup on the web. The last two need the Firebase Apple
  /// provider's Services ID set up. Returns null when the user backs out.
  ///
  /// Apple shares the user's name only on their first authorisation, and may
  /// hand over a private-relay email, so the Firestore display name can come
  /// out as a random-looking prefix or `Player_xxxxxx`. `onUserCreated`
  /// sanitises it and the user can change it in Settings.
  Future<User?> signInWithApple() async {
    if (_isWeb) return _signInWithPopup(appleAuthProvider(), 'apple');
    try {
      final userCredential =
          await _firebaseAuth.signInWithProvider(appleAuthProvider());
      return userCredential.user;
    } on FirebaseAuthException catch (e) {
      if (isProviderSignInCancelled(e)) return null;
      CrashlyticsHelper.recordHandled(e, StackTrace.current,
          reason: 'apple_sign_in:${e.code}',
          dedupeKey: 'apple_sign_in:${e.code}');
      rethrow;
    }
  }

  Future<void> signInWithCredentials(String email, String password) {
    return _firebaseAuth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
  }

  Future<UserCredential> signUp({required String email, required String password}) async {
    final credential = await _firebaseAuth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    final user = credential.user;
    if (user != null) {
      // Set the display name in Firebase Auth so the profile is immediately
      // readable from FirebaseAuth.currentUser.displayName. The Firestore
      // profile (users/{uid}) is created by the onUserCreated Cloud Function,
      // which applies the same sanitisation logic server-side.
      final prefix = email.split('@').first;
      final name = Validators.isValidDisplayName(prefix)
          ? prefix
          : 'Player_${user.uid.substring(0, 6)}';
      await user.updateDisplayName(name);
    }
    return credential;
  }

  /// If the current user's Firestore profile is missing a displayName,
  /// calls the updateDisplayName Cloud Function to backfill it from their
  /// Firebase Auth profile (falling back to Player_XXXXXX). Errors are
  /// silently swallowed — this is best-effort repair, not a critical path.
  Future<void> backfillDisplayNameIfMissing() async {
    final user = _firebaseAuth.currentUser;
    if (user == null) return;
    // Skip silently during maintenance — re-runs naturally on the next launch.
    if (MaintenanceGuard.isOn) return;
    try {
      final doc = await _firestore.collection('users').doc(user.uid).get();
      final existing = doc.exists
          ? (doc.data()?['displayName'] as String? ?? '').trim()
          : '';
      if (existing.isNotEmpty) return; // already set — nothing to do
      final raw = user.displayName?.trim() ??
          (user.email != null ? user.email!.split('@').first : '');
      final name = Validators.isValidDisplayName(raw)
          ? raw
          : 'Player_${user.uid.substring(0, 6)}';
      final callable = appFunctions.httpsCallable('updateDisplayName');
      await callable.call({'name': name});
      await user.reload();
    } catch (_) {
      // Non-fatal: the user can always set their name manually in Settings.
    }
  }

  /// Fetches the display name for any user by UID.
  Future<String?> getDisplayName(String uid) async {
    final doc = await _firestore.collection('users').doc(uid).get();
    return doc.data()?['displayName'] as String?;
  }

  /// Updates the current user's display name via a server-side Cloud Function
  /// that enforces the profanity filter and updates both Firebase Auth and
  /// Firestore atomically. After success, reloads the Auth profile so
  /// [FirebaseAuth.currentUser.displayName] reflects the change immediately.
  Future<void> updateDisplayName(String newName) async {
    final user = _firebaseAuth.currentUser;
    if (user == null) return;
    final callable = appFunctions.httpsCallable('updateDisplayName');
    await callable.call({'name': newName});
    // Reload so the in-memory Auth profile picks up the name set by the
    // Admin SDK on the server.
    await user.reload();
  }

  /// Sends a password reset email to [email].
  /// Uses a generic success message on the calling side to prevent user
  /// enumeration — do not surface whether the address is registered.
  Future<void> sendPasswordResetEmail(String email) {
    return _firebaseAuth.sendPasswordResetEmail(email: email);
  }

  /// Reauthenticates with [currentPassword] then updates to [newPassword].
  /// Throws [FirebaseAuthException] on wrong current password or network error.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final user = _firebaseAuth.currentUser;
    if (user == null || user.email == null) {
      throw FirebaseAuthException(code: 'no-current-user');
    }
    final credential = EmailAuthProvider.credential(
      email: user.email!,
      password: currentPassword,
    );
    await user.reauthenticateWithCredential(credential);
    await user.updatePassword(newPassword);
  }

  /// Permanently deletes the signed-in user's Firebase Auth account. Firebase
  /// requires a recent login for [User.delete], so this re-authenticates first:
  /// password users supply [currentPassword]; Google and Apple users re-run
  /// their provider's sign-in to obtain a fresh credential.
  ///
  /// Apple users additionally have their Apple tokens revoked, which App Store
  /// guideline 5.1.1(v) requires of any app offering Sign in with Apple. This
  /// needs the Apple provider's OAuth code-flow settings (Team ID, Key ID,
  /// private key) in the Firebase console; if revocation fails the deletion
  /// still goes ahead, because erasing the user's data matters more. Only the
  /// native iOS flow returns the authorisation code revocation needs, so on
  /// Android and the web the tokens simply lapse when the account is deleted.
  ///
  /// The `onUserDeleted` Cloud Function then erases / anonymises the user's
  /// Firestore + Storage data. Throws [FirebaseAuthException] on wrong password,
  /// `requires-recent-login`, or no current user.
  ///
  /// Returns false, having deleted nothing, when a Google or Apple user
  /// dismisses the re-authentication prompt: backing out is not a failure, so
  /// the caller should just return to idle (as [signInWithGoogle] and
  /// [signInWithApple] do) rather than report that the deletion failed.
  Future<bool> deleteAccount({String? currentPassword}) async {
    final user = _firebaseAuth.currentUser;
    if (user == null) {
      throw FirebaseAuthException(code: 'no-current-user');
    }
    final providers = user.providerData.map((p) => p.providerId).toSet();

    if (providers.contains('password')) {
      if (user.email == null || currentPassword == null || currentPassword.isEmpty) {
        // The UI prompts for the password before calling; treat a missing one
        // as a wrong-password so the same error message is shown.
        throw FirebaseAuthException(code: 'wrong-password');
      }
      final credential = EmailAuthProvider.credential(
        email: user.email!,
        password: currentPassword,
      );
      await user.reauthenticateWithCredential(credential);
    } else if (providers.contains('google.com') && _isWeb) {
      if (!await _reauthenticateWithPopup(user, GoogleAuthProvider())) {
        return false;
      }
    } else if (providers.contains('google.com')) {
      final GoogleSignInAccount googleUser;
      try {
        googleUser = await _googleSignIn.authenticate();
      } on GoogleSignInException catch (e) {
        if (e.code == GoogleSignInExceptionCode.canceled ||
            e.code == GoogleSignInExceptionCode.interrupted) {
          return false;
        }
        rethrow;
      }
      final googleAuth = googleUser.authentication;
      final credential = GoogleAuthProvider.credential(idToken: googleAuth.idToken);
      await user.reauthenticateWithCredential(credential);
    } else if (providers.contains('apple.com')) {
      final UserCredential reauth;
      try {
        reauth = _isWeb
            ? await user.reauthenticateWithPopup(appleAuthProvider())
            : await user.reauthenticateWithProvider(appleAuthProvider());
      } on FirebaseAuthException catch (e) {
        if (isProviderSignInCancelled(e)) return false;
        rethrow;
      }
      final authCode = reauth.additionalUserInfo?.authorizationCode;
      if (authCode != null) {
        try {
          await _firebaseAuth.revokeTokenWithAuthorizationCode(authCode);
        } catch (e, st) {
          CrashlyticsHelper.recordHandled(e, st,
              reason: 'apple_token_revoke', dedupeKey: 'apple_token_revoke');
        }
      }
    }

    await user.delete();

    // Erase the local claim outbox too. `onUserDeleted` clears the server
    // side, but banked offline captures live in SharedPreferences and hold
    // this user's GPS positions and timestamps. They can never settle now the
    // account is gone, so leaving them to age out of the 36 h grace window
    // would keep the location data of someone who has just asked to be erased.
    // Deliberately NOT done on sign-out, where entries must survive so the
    // same user can flush them after signing back in.
    //
    // NOT awaited, and bounded. The account is already gone server-side by
    // this line, so nothing here may delay the caller — and
    // SharedPreferences.getInstance() HANGS rather than throwing when the
    // platform channel is unavailable, so a try/catch alone would leave the
    // user watching a spinner forever. Worst case the entries age out instead.
    unawaited(
      ClaimOutbox.instance
          .clearAll()
          .timeout(const Duration(seconds: 5))
          .catchError((Object _) {}),
    );

    // Best-effort: clear any lingering Google session so the next sign-in
    // shows the account chooser rather than silently re-using the deleted one.
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
    return true;
  }

  /// Re-authenticates [user] with [provider] in a popup (web). Returns false
  /// when the user closes it.
  Future<bool> _reauthenticateWithPopup(
      User user, AuthProvider provider) async {
    try {
      await user.reauthenticateWithPopup(provider);
      return true;
    } on FirebaseAuthException catch (e) {
      if (isProviderSignInCancelled(e)) return false;
      rethrow;
    }
  }

  Future<void> signOut() async {
    await Future.wait([
      _firebaseAuth.signOut(),
      _googleSignIn.signOut(),
    ]);
  }

  Future<bool> isSignedIn() async {
    final currentUser = _firebaseAuth.currentUser;
    return currentUser != null;
  }

  /// Uid of the signed-in user, or null when signed out. Used by the Wear
  /// shell to key its widget tree so per-user streams and scan state are
  /// remounted on any auth change (sign-in, sign-out, account switch).
  String? get currentUid => _firebaseAuth.currentUser?.uid;
}
