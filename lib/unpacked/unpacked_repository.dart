import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:postbox_game/admin/admin_access.dart';
import 'package:postbox_game/london_date.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/unpacked/unpacked_stats.dart';

/// A recap that is ready to show: the community summary plus the signed-in
/// player's own snapshot.
class UnpackedRecap {
  const UnpackedRecap({
    required this.summary,
    required this.stats,
    this.friendNames = const {},
  });
  final UnpackedSummary summary;
  final UnpackedStats stats;

  /// Display names for [UnpackedStats.friendStreaks], looked up when the
  /// recap loaded. A friend missing here (a deleted account, or the lookup
  /// failed) is left off the card.
  final Map<String, String> friendNames;
  int get year => stats.year;
}

/// Reads the server-built "Your Postboxes Unpacked" snapshots and decides
/// whether the recap should be offered at all.
///
/// The recap is shown when ALL of:
///   * the `unpacked_enabled` Remote Config flag is on — or the user is an
///     admin (soft launch: admins see it before the flag flips);
///   * today is inside the summary's window (19 Dec – 15 Jan) — admins bypass
///     this too, so the pre-launch build can be checked in late November;
///   * the `unpacked/{year}` summary and this player's snapshot both exist
///     and the snapshot has at least one claim.
class UnpackedRepository {
  UnpackedRepository({
    FirebaseFirestore? firestore,
    RemoteConfigService? config,
    Future<bool> Function()? isAdmin,
    String Function()? today,
  })  : _firestore = firestore,
        _config = config,
        _isAdmin = isAdmin ?? AdminAccess.isAdmin,
        _today = today ?? todayLondon;

  final FirebaseFirestore? _firestore;
  final RemoteConfigService? _config;
  final Future<bool> Function() _isAdmin;
  final String Function() _today;

  // Resolved lazily (inside load's try) so constructing a repository never
  // throws where Firebase isn't initialised, e.g. widget tests of Home.
  FirebaseFirestore get _db => _firestore ?? FirebaseFirestore.instance;

  RemoteConfigService get _rc => _config ?? RemoteConfigService.instance;

  DocumentReference<Map<String, dynamic>> _summaryRef(int year) =>
      _db.collection('unpacked').doc('$year');

  DocumentReference<Map<String, dynamic>> _playerRef(int year, String uid) =>
      _summaryRef(year).collection('players').doc(uid);

  /// Names for the friends on the "Longest streak" and award cards. A friend
  /// whose
  /// user doc is gone (account deleted) is skipped; any failure just leaves
  /// the friends off rather than hiding the recap.
  Future<Map<String, String>> _friendNames(UnpackedStats stats) async {
    final uids = stats.friendUids;
    if (uids.isEmpty) return const {};
    try {
      final docs = await Future.wait([
        for (final uid in uids) _db.collection('users').doc(uid).get(),
      ]);
      return {
        for (final d in docs)
          if (d.exists)
            d.id:
                (d.data()?['displayName'] as String?)?.trim().isNotEmpty == true
                    ? (d.data()!['displayName'] as String).trim()
                    : 'A friend',
      };
    } catch (e) {
      debugPrint('UnpackedRepository: friend names failed: $e');
      return const {};
    }
  }

  /// The recap to offer [uid] right now, or null when there is none. Never
  /// throws: any failure (offline, permission) simply hides the recap.
  Future<UnpackedRecap?> load(String uid) async {
    try {
      final admin = await _isAdmin();
      // Cheapest gate first: with the flag off, ordinary players cost no
      // Firestore reads at all on every Home load.
      if (!_rc.unpackedEnabled && !admin) return null;

      final today = _today();
      final years = <int>{
        // Admins checking a pre-December build want THIS year's snapshot,
        // which unpackedYearFor only reaches from 1 December.
        if (admin) int.parse(today.substring(0, 4)),
        unpackedYearFor(today),
      };
      for (final year in years) {
        final summarySnap = await _summaryRef(year).get();
        final summaryData = summarySnap.data();
        if (summaryData == null) continue;
        final summary = UnpackedSummary.fromMap(summaryData, year: year);
        if (!admin && !summary.isOpenOn(today)) continue;

        final playerData = (await _playerRef(year, uid).get()).data();
        if (playerData == null) continue;
        final stats = UnpackedStats.fromMap(playerData, year: year);
        if (stats.isEmpty) continue;
        return UnpackedRecap(
          summary: summary,
          stats: stats,
          friendNames: await _friendNames(stats),
        );
      }
      return null;
    } catch (e) {
      debugPrint('UnpackedRepository.load failed: $e');
      return null;
    }
  }
}
