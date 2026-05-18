import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:postbox_game/london_date.dart';

/// Pure helper: returns the user-facing streak value given the stored streak
/// and the user's last-claim date.
///
/// The server only writes [storedStreak] when a claim happens, so a user who
/// missed yesterday would otherwise still see their old streak until the next
/// claim overwrote it. Streak is "fresh" only when [lastClaimDate] is [today]
/// or [yesterday]; otherwise we present 0 to the UI even though the field on
/// the user doc is still non-zero.
///
/// Returns null when the stored streak is null (user doc has no streak field
/// yet — e.g. an account that has never claimed); callers that need an int
/// instead can fall back to 0.
int? freshStreak({
  required int? storedStreak,
  required String? lastClaimDate,
  required String today,
  required String yesterday,
}) {
  if (storedStreak == null || storedStreak == 0) return storedStreak;
  if (lastClaimDate == null) return 0;
  if (lastClaimDate == today || lastClaimDate == yesterday) return storedStreak;
  return 0;
}

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
      return freshStreak(
        storedStreak: (data['streak'] as num?)?.toInt(),
        lastClaimDate: data['lastClaimDate'] as String?,
        today: todayLondon(),
        yesterday: yesterdayLondon(),
      );
    });
  }
}
