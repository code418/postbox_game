import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:postbox_game/london_date.dart';

/// Updates and reads daily claim streak for the current user.
class StreakService {
  StreakService({FirebaseFirestore? firestore, FirebaseAuth? auth})
      : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  /// Stream of the current user's streak (for UI).
  ///
  /// Returns 0 when the stored streak is stale — i.e. the user last claimed
  /// before yesterday (London time). Without this check, a user who missed
  /// yesterday would still see their old streak value until their next claim
  /// overwrote it. The server `streak` field only updates on a claim, so
  /// client-side staleness detection is the only way to reflect breaks live.
  Stream<int?> streakStream() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return Stream<int?>.value(null);
    return _firestore.collection('users').doc(uid).snapshots().map((s) {
      final data = s.data();
      if (data == null) return null;
      final storedStreak = (data['streak'] as num?)?.toInt();
      if (storedStreak == null || storedStreak == 0) return storedStreak;
      final lastClaimDate = data['lastClaimDate'] as String?;
      if (lastClaimDate == null) return 0;
      final today = todayLondon();
      final yesterday = yesterdayLondon();
      if (lastClaimDate == today || lastClaimDate == yesterday) {
        return storedStreak;
      }
      return 0;
    });
  }
}
