// In-memory cache of the last successful claim-radius scan (ROADMAP v1.5,
// offline play Phase 3 — the warm path).
//
// The nearbyPostboxes payload contains NO coordinates (applyUserClaims strips
// them server-side), so caching it leaks nothing. Together with the scanId
// token it lets the claim sheet rescue the common real failure — "scanned,
// walked to the box, signal died mid-claim" — by serving the last scan's
// results and banking the claim to the outbox.
//
// Deliberately process-lifetime only (not persisted): the rescue targets the
// same outing, the token window is short, and keeping it off disk keeps the
// surface small.

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/london_date.dart';

class CachedScan {
  const CachedScan({
    required this.data,
    required this.scanId,
    required this.position,
    required this.fetchedAtMs,
    this.uid,
  });

  /// Who the scan (and its [scanId] token) belongs to. The cache is
  /// process-global but a token is bound to one uid server-side, so serving it
  /// to a different account would show them someone else's claimed/unclaimed
  /// counts and bank a capture that can only come back `bad_token`.
  final String? uid;

  /// The parsed nearbyPostboxes response (counts/points/postboxes/compass —
  /// coordinate-free by server contract).
  final Map<String, dynamic> data;

  /// The HMAC capture token issued with this scan.
  final String scanId;

  /// Where the scan was taken (client-side knowledge, needed to judge
  /// whether the user is still standing in the scanned spot).
  final LatLng position;

  final int fetchedAtMs;
}

class ScanCache {
  ScanCache._();

  /// How long a cached scan stays usable for the offline rescue. Comfortably
  /// inside any sane server-side capture window.
  static const Duration maxAge = Duration(hours: 2);

  static CachedScan? _last;

  static void store(CachedScan scan) => _last = scan;

  /// Drop the cached scan. Called when the signed-in user changes so the next
  /// account can't be served the previous one's results or capture token.
  static void clear() => _last = null;

  /// The cached scan if it is fresh enough, from the current London day, AND
  /// belongs to [uid], else null. A null [uid] on either side matches, which
  /// keeps the headless tests and any pre-uid cache entry working.
  static CachedScan? fresh({DateTime? now, String? uid}) {
    final last = _last;
    if (last == null) return null;
    if (uid != null && last.uid != null && last.uid != uid) return null;
    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    if (nowMs - last.fetchedAtMs > maxAge.inMilliseconds) return null;
    // The payload's claimedToday flags describe the London day it was taken
    // on. Past midnight those boxes are claimable again, but replaying the
    // scan would still mark them claimed, hiding the claim button and leaving
    // the quiz nothing to ask about for captures the server would accept.
    if (formatLondon(DateTime.fromMillisecondsSinceEpoch(last.fetchedAtMs,
            isUtc: true)) !=
        formatLondon(DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true))) {
      return null;
    }
    return last;
  }

  @visibleForTesting
  static void resetForTest() => _last = null;
}
