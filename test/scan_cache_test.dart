// Unit tests for ScanCache (ROADMAP v1.5, offline play Phase 3).
//
// The cache holds the last successful nearbyPostboxes payload so the claim
// sheet can rescue "scanned, walked to the box, signal died mid-claim". It is
// process-global, so it also has to be scoped to the account that scanned:
// the cached scanId is an HMAC token bound to one uid server-side, and the
// payload carries that user's claimed/unclaimed counts.

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/services/scan_cache.dart';

CachedScan _scan({String? uid, int? fetchedAtMs}) => CachedScan(
      data: const {'counts': {'total': 1}},
      scanId: 'tok-1',
      position: const LatLng(51.5, -0.12),
      fetchedAtMs: fetchedAtMs ?? DateTime.now().millisecondsSinceEpoch,
      uid: uid,
    );

void main() {
  setUp(ScanCache.resetForTest);

  test('a fresh scan is served back', () {
    ScanCache.store(_scan());
    expect(ScanCache.fresh()?.scanId, 'tok-1');
  });

  test('a scan older than maxAge is not served', () {
    ScanCache.store(_scan(
      fetchedAtMs: DateTime.now().millisecondsSinceEpoch -
          ScanCache.maxAge.inMilliseconds -
          1000,
    ));
    expect(ScanCache.fresh(), isNull);
  });

  test('a scan is not served to a different account', () {
    ScanCache.store(_scan(uid: 'userA'));
    expect(ScanCache.fresh(uid: 'userB'), isNull,
        reason: "userB would see userA's counts and bank an unusable token");
    expect(ScanCache.fresh(uid: 'userA')?.scanId, 'tok-1');
  });

  test('a null uid on either side still matches', () {
    ScanCache.store(_scan(uid: 'userA'));
    expect(ScanCache.fresh(), isNotNull, reason: 'caller did not ask');
    ScanCache.store(_scan());
    expect(ScanCache.fresh(uid: 'userB'), isNotNull, reason: 'pre-uid entry');
  });

  test('clear drops the cache so the next account starts empty', () {
    ScanCache.store(_scan(uid: 'userA'));
    ScanCache.clear();
    expect(ScanCache.fresh(uid: 'userA'), isNull);
  });
}
