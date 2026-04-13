import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Updates and reads daily claim streak for the current user.
class StreakService {
  StreakService({FirebaseFirestore? firestore, FirebaseAuth? auth})
      : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  /// Stream of the current user's streak (for UI).
  Stream<int?> streakStream() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return Stream<int?>.value(null);
    return _firestore.collection('users').doc(uid).snapshots().map((s) {
      return (s.data()?['streak'] as num?)?.toInt();
    });
  }
}
