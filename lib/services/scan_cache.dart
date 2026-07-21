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

class CachedScan {
  const CachedScan({
    required this.data,
    required this.scanId,
    required this.position,
    required this.fetchedAtMs,
  });

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

  /// The cached scan if it is fresh enough, else null.
  static CachedScan? fresh({DateTime? now}) {
    final last = _last;
    if (last == null) return null;
    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    if (nowMs - last.fetchedAtMs > maxAge.inMilliseconds) return null;
    return last;
  }

  @visibleForTesting
  static void resetForTest() => _last = null;
}
