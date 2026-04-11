import 'package:cloud_firestore/cloud_firestore.dart';
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
    final user = userCredential.user;
    if (user != null) {
      if (userCredential.additionalUserInfo?.isNewUser == true) {
        // First sign-in: seed the profile. Subsequent sign-ins must not
        // overwrite a custom display name the user may have set.
        await _saveUserProfile(
            user.uid, user.displayName ?? user.email ?? '', user.email ?? '');
      } else {
        // Returning user: keep existing displayName, but update email in case
        // it changed on the Google account.
        await _firestore.collection('users').doc(user.uid).set(
          {'email': user.email ?? ''},
          SetOptions(merge: true),
        );
      }
    }
    return user;
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
      // Use the part of the email before @ as the initial display name,
      // but fall back to Player_<uid> if the prefix fails the profanity filter.
      final prefix = email.split('@').first;
      final name = Validators.isValidDisplayName(prefix)
          ? prefix
          : 'Player_${user.uid.substring(0, 6)}';
      await user.updateDisplayName(name);
      await _saveUserProfile(user.uid, name, email);
    }
    return credential;
  }

  /// Persists uid + displayName + email to Firestore so friends can resolve names.
  Future<void> _saveUserProfile(String uid, String displayName, String email) async {
    await _firestore.collection('users').doc(uid).set(
      {'displayName': displayName, 'email': email},
      SetOptions(merge: true),
    );
  }

  /// Fetches the display name for any user by UID.
  Future<String?> getDisplayName(String uid) async {
    final doc = await _firestore.collection('users').doc(uid).get();
    return doc.data()?['displayName'] as String?;
  }

  /// Updates the current user's display name in both Firebase Auth and Firestore.
  Future<void> updateDisplayName(String newName) async {
    final user = _firebaseAuth.currentUser;
    if (user == null) return;
    // Use set+merge rather than update() so this never throws 'not-found' if
    // the users/{uid} document was not yet created by the onUserCreated trigger.
    await Future.wait([
      user.updateDisplayName(newName),
      _firestore.collection('users').doc(user.uid).set(
        {'displayName': newName},
        SetOptions(merge: true),
      ),
    ]);
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
