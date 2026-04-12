import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:postbox_game/validators.dart';

class UserRepository {
  final FirebaseAuth _firebaseAuth;
  final GoogleSignIn _googleSignIn;
  final FirebaseFirestore _firestore;

  UserRepository({FirebaseAuth? firebaseAuth, GoogleSignIn? googleSignin, FirebaseFirestore? firestore})
      : _firebaseAuth = firebaseAuth ?? FirebaseAuth.instance,
        _googleSignIn = googleSignin ?? GoogleSignIn(),
        _firestore = firestore ?? FirebaseFirestore.instance;

  Future<User?> signInWithGoogle() async {
    final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
    if (googleUser == null) return null; // user cancelled
    final GoogleSignInAuthentication googleAuth =
        await googleUser.authentication;
    final AuthCredential credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );
    final userCredential = await _firebaseAuth.signInWithCredential(credential);
    // The onUserCreated Cloud Function creates the Firestore profile
    // (displayName, createdAt) when a new Auth user is first created.
    // No client-side Firestore write is needed here.
    return userCredential.user;
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
      final callable = FirebaseFunctions.instance.httpsCallable('updateDisplayName');
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
    final callable = FirebaseFunctions.instance.httpsCallable('updateDisplayName');
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
}
