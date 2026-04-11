import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Updates and reads daily claim streak for the current user.
class StreakService {
  StreakService({FirebaseFirestore? firestore, FirebaseAuth? auth})
      : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  static String get _today {
    // Use device local date. For this UK-only app the device is expected to be
    // set to a UK timezone (Europe/London), which matches what Cloud Functions
    // record as dailyDate. Manual DST arithmetic here is error-prone and
    // incorrect around actual switchover days.
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  /// Call after user successfully claims (e.g. startScoring returned found with claims).
  ///
  /// Pass [claimDate] (the `dailyDate` returned by the Cloud Function) so the
  /// streak uses the server-side London date rather than device local time.
  /// Falls back to device time if [claimDate] is null (e.g. older clients).
  Future<void> updateStreakAfterClaim({String? claimDate}) async {
    final user = _auth.currentUser;
    if (user == null) return;

    final today = claimDate ?? _today;
    final todayDate = DateTime.parse(today);
    final yesterday = todayDate
        .subtract(const Duration(days: 1))
        .toIso8601String()
        .split('T')
        .first;

    final ref = _firestore.collection('users').doc(user.uid);
    await _firestore.runTransaction((tx) async {
      final doc = await tx.get(ref);
      final data = doc.data() ?? {};
      final lastClaimDate = data['lastClaimDate'] as String?;
      final currentStreak = (data['streak'] as int?) ?? 0;

      int newStreak;
      if (lastClaimDate == today) {
        return; // Already claimed today
      } else if (lastClaimDate == yesterday) {
        newStreak = currentStreak + 1;
      } else {
        newStreak = 1;
      }

      tx.set(ref, {
        'lastClaimDate': today,
        'streak': newStreak,
      }, SetOptions(merge: true));
    });
  }

  /// Stream of the current user's streak (for UI).
  Stream<int?> streakStream() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return Stream<int?>.value(null);
    return _firestore.collection('users').doc(uid).snapshots().map((s) {
      final d = s.data();
      if (d == null || d['streak'] is! int) return null;
      return d['streak'] as int;
    });
  }
}
