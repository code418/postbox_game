import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:postbox_game/admin/admin_access.dart';
import 'package:postbox_game/london_date.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/unpacked/unpacked_stats.dart';

/// A recap that is ready to show: the community summary plus the signed-in
/// player's own snapshot.
class UnpackedRecap {
  const UnpackedRecap({required this.summary, required this.stats});
  final UnpackedSummary summary;
  final UnpackedStats stats;
  int get year => stats.year;
}

/// Reads the server-built "Your Postboxes Unpacked" snapshots and decides
/// whether the recap should be offered at all.
///
/// The recap is shown when ALL of:
///   * the `unpacked_enabled` Remote Config flag is on — or the user is an
///     admin (soft launch: admins see it before the flag flips);
///   * today is inside the summary's window (1 Dec – 15 Jan) — admins bypass
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
        return UnpackedRecap(summary: summary, stats: stats);
      }
      return null;
    } catch (e) {
      debugPrint('UnpackedRepository.load failed: $e');
      return null;
    }
  }
}
