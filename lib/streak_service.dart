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
      final today = _todayLondon();
      final yesterday = _yesterdayLondon();
      if (lastClaimDate == today || lastClaimDate == yesterday) {
        return storedStreak;
      }
      return 0;
    });
  }
}

// ── London-date helpers ────────────────────────────────────────────────────
// Duplicated from home_widget_service.dart to avoid a cross-service import.
// Both rely on knowing when BST/GMT applies; keep in sync.

String _todayLondon() => _formatLondon(DateTime.now().toUtc());

String _yesterdayLondon() {
  final yesterdayUtc = DateTime.now().toUtc().subtract(const Duration(days: 1));
  return _formatLondon(yesterdayUtc);
}

String _formatLondon(DateTime utc) {
  final offset = _isBst(utc) ? const Duration(hours: 1) : Duration.zero;
  final london = utc.add(offset);
  final y = london.year.toString().padLeft(4, '0');
  final m = london.month.toString().padLeft(2, '0');
  final d = london.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

bool _isBst(DateTime utc) {
  final year = utc.year;
  final bstStart = _lastSundayOfMonthUtcAt01(year, 3);
  final bstEnd = _lastSundayOfMonthUtcAt01(year, 10);
  return !utc.isBefore(bstStart) && utc.isBefore(bstEnd);
}

DateTime _lastSundayOfMonthUtcAt01(int year, int month) {
  final lastDay = DateTime.utc(year, month + 1, 0);
  final offsetToSunday = lastDay.weekday % 7;
  final sunday = lastDay.subtract(Duration(days: offsetToSunday));
  return DateTime.utc(sunday.year, sunday.month, sunday.day, 1);
}
