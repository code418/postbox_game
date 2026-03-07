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
    final now = DateTime.now().toUtc();
    // Approximate BST: last Sunday March → last Sunday October
    // BST = UTC+1, GMT = UTC+0
    final month = now.month;
    final isDstCandidate = month > 3 && month < 10 ||
        (month == 3 && now.day > 24) || // last week of March (rough)
        (month == 10 && now.day <= 24); // first 3 weeks of October (rough)
    final london = isDstCandidate
        ? now.add(const Duration(hours: 1))
        : now;
    return london.toIso8601String().split('T').first;
  }

  /// Call after user successfully claims (e.g. startScoring returned found with claims).
  Future<void> updateStreakAfterClaim() async {
    final user = _auth.currentUser;
    if (user == null) return;

    final today = _today;
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
