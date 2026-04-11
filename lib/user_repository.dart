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

  Future<String?> getUser() async {
    return _firebaseAuth.currentUser?.email;
  }
}
