// Unit tests for ClaimOutbox (ROADMAP v1.5, offline play Phase 3).
//
// The outbox persists offline claim captures in SharedPreferences as a JSON
// list and exposes a pendingCount listenable for the OfflineBanner. Capture
// times are anchored monotonically: each entry stores the wall clock AND the
// process-monotonic elapsed at capture, so a flush in the SAME process can
// correct for a device clock changed mid-outing (an NTP resync yielding a
// zero delta reads as 2400 m/min and spuriously rejects an honest user).

import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/services/claim_outbox.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ClaimOutbox.resetForTest();
  });

  test('add persists an entry and survives a reload round-trip', () async {
    final outbox = ClaimOutbox.instance;
    await outbox.add(OutboxEntry(
      scanId: 'tok1',
      lat: 51.5,
      lng: -0.12,
      capturedWallMs: 1000,
      capturedMonotonicMs: 500,
      attemptId: 'att1',
    ));
    expect(outbox.pendingCount.value, 1);

    // A fresh instance (new process) reloads from storage.
    ClaimOutbox.resetForTest();
    final reloaded = ClaimOutbox.instance;
    final entries = await reloaded.entries();
    expect(entries, hasLength(1));
    expect(entries.single.scanId, 'tok1');
    expect(entries.single.attemptId, 'att1');
    expect(reloaded.pendingCount.value, 1);
  });

  test('removeByAttemptIds drops settled entries and updates the count', () async {
    final outbox = ClaimOutbox.instance;
    await outbox.add(OutboxEntry(
        scanId: 't1', lat: 1, lng: 2, capturedWallMs: 1, capturedMonotonicMs: 1, attemptId: 'a1'));
    await outbox.add(OutboxEntry(
        scanId: 't2', lat: 1, lng: 2, capturedWallMs: 2, capturedMonotonicMs: 2, attemptId: 'a2'));
    await outbox.removeByAttemptIds({'a1'});
    final entries = await outbox.entries();
    expect(entries.map((e) => e.attemptId), ['a2']);
    expect(outbox.pendingCount.value, 1);
  });

  test('pruneExpired drops entries older than the grace window', () async {
    final outbox = ClaimOutbox.instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    await outbox.add(OutboxEntry(
        scanId: 'old', lat: 1, lng: 2,
        capturedWallMs: now - 48 * 3600000, capturedMonotonicMs: 0, attemptId: 'a1'));
    await outbox.add(OutboxEntry(
        scanId: 'fresh', lat: 1, lng: 2,
        capturedWallMs: now - 3600000, capturedMonotonicMs: 0, attemptId: 'a2'));
    final dropped = await outbox.pruneExpired(graceHours: 36);
    expect(dropped, 1);
    final entries = await outbox.entries();
    expect(entries.single.scanId, 'fresh');
  });

  test('caps the queue: adding beyond the cap drops the oldest', () async {
    final outbox = ClaimOutbox.instance;
    for (var i = 0; i < ClaimOutbox.maxEntries + 5; i++) {
      await outbox.add(OutboxEntry(
          scanId: 't$i', lat: 1, lng: 2,
          capturedWallMs: i, capturedMonotonicMs: i, attemptId: 'a$i'));
    }
    final entries = await outbox.entries();
    expect(entries, hasLength(ClaimOutbox.maxEntries));
    expect(entries.first.scanId, 't5', reason: 'oldest entries dropped first');
  });

  test('corrupt stored JSON resets to an empty outbox instead of throwing', () async {
    SharedPreferences.setMockInitialValues(
        {'claim_outbox_v1': 'not valid json'});
    ClaimOutbox.resetForTest();
    final entries = await ClaimOutbox.instance.entries();
    expect(entries, isEmpty);
  });

  test('flushCaptureTimes anchors to the monotonic clock in-process', () {
    // Captured at monotonic 10s with wall clock W. At flush IN THE SAME PROCESS
    // (matching boot id), monotonic is 70s and the wall clock has been set BACK
    // an hour: the anchored capture time must be flushWall - 60s, not the (now
    // bogus) stored wall clock.
    final entry = OutboxEntry(
        scanId: 't', lat: 1, lng: 2,
        capturedWallMs: 5000000, capturedMonotonicMs: 10000, attemptId: 'a',
        capturedBootId: 'boot-1');
    final anchored = entry.capturedAtForFlush(
        flushWallMs: 2000000, flushMonotonicMs: 70000, flushBootId: 'boot-1');
    expect(anchored, 2000000 - 60000);
  });

  test('flushCaptureTimes falls back to the stored wall clock across restarts', () {
    // A restart mints a new boot id: even when the new process's monotonic
    // clock happens to be smaller than the stored one, fall back to wall time.
    final entry = OutboxEntry(
        scanId: 't', lat: 1, lng: 2,
        capturedWallMs: 5000000, capturedMonotonicMs: 90000, attemptId: 'a',
        capturedBootId: 'boot-old');
    final anchored = entry.capturedAtForFlush(
        flushWallMs: 9000000, flushMonotonicMs: 20000, flushBootId: 'boot-new');
    expect(anchored, 5000000);
  });

  test('flushCaptureTimes does NOT anchor across a restart even when the new '
      'process outran the old monotonic value', () {
    // Regression: the bare `flushMonotonic >= capturedMonotonic` guard was a
    // false same-process signal. A capture taken 10s into the OLD process
    // (capturedMonotonic 10s), flushed 70s into a NEW process (different boot
    // id) whose stopwatch has already passed 10s, must still use the stored
    // wall clock — anchoring here would report the capture as ~now and mis-date
    // an offline claim (and its streak) to the flush day.
    final entry = OutboxEntry(
        scanId: 't', lat: 1, lng: 2,
        capturedWallMs: 5000000, capturedMonotonicMs: 10000, attemptId: 'a',
        capturedBootId: 'boot-old');
    final anchored = entry.capturedAtForFlush(
        flushWallMs: 2000000, flushMonotonicMs: 70000, flushBootId: 'boot-new');
    expect(anchored, 5000000,
        reason: 'cross-process must never take the monotonic anchor');
  });

  test('flushCaptureTimes falls back to wall clock for legacy entries with no '
      'boot id', () {
    // Entries written before capturedBootId existed can never be proven
    // same-process, so they always use the stored wall clock.
    final entry = OutboxEntry(
        scanId: 't', lat: 1, lng: 2,
        capturedWallMs: 5000000, capturedMonotonicMs: 10000, attemptId: 'a');
    final anchored = entry.capturedAtForFlush(
        flushWallMs: 2000000, flushMonotonicMs: 70000, flushBootId: 'boot-x');
    expect(anchored, 5000000);
  });

  test('add stamps the capturing process boot id and it round-trips', () async {
    final outbox = ClaimOutbox.instance;
    await outbox.add(OutboxEntry(
        scanId: 't', lat: 1, lng: 2,
        capturedWallMs: 1000, capturedMonotonicMs: 500, attemptId: 'a'));
    // A fresh instance (simulated new process) reloads from storage; the static
    // boot id persists, so the stamped id still matches the live one.
    ClaimOutbox.resetForTest();
    final reloaded = await ClaimOutbox.instance.entries();
    expect(reloaded.single.capturedBootId, ClaimOutbox.bootId(),
        reason: 'the boot id is stamped at add() and survives reload');
  });

  group('account scoping', () {
    // The outbox is device-global but its contents are user-bound: the scan
    // token embeds the uid, so a flush by a different account comes back
    // `bad_token` — a PERMANENT reason, which would make OutboxSync delete the
    // original user's captures. Entries are therefore owner-stamped and hidden
    // from everyone else.
    OutboxEntry entry(String id) => OutboxEntry(
          scanId: 'tok-$id',
          lat: 51.5,
          lng: -0.12,
          capturedWallMs: DateTime.now().millisecondsSinceEpoch,
          capturedMonotonicMs: 0,
          attemptId: id,
        );

    ClaimOutbox outboxFor(String? uid) =>
        ClaimOutbox(uidProvider: () => uid);

    test('add stamps the signed-in owner and it survives a reload', () async {
      await outboxFor('userA').add(entry('a1'));
      final reloaded = await outboxFor('userA').entries();
      expect(reloaded.single.uid, 'userA');
    });

    test("another account never sees or counts the previous user's captures",
        () async {
      final a = outboxFor('userA');
      await a.add(entry('a1'));
      await a.add(entry('a2'));
      expect(a.pendingCount.value, 2);

      final b = outboxFor('userB');
      expect(await b.entries(), isEmpty,
          reason: "userB flushing userA's tokens would destroy them");
      expect(b.pendingCount.value, 0);

      // ...and they are still there when userA comes back.
      expect(await outboxFor('userA').entries(), hasLength(2));
    });

    test('signed out, only legacy unowned entries are visible', () async {
      await outboxFor('userA').add(entry('a1'));
      expect(await outboxFor(null).entries(), isEmpty);
    });

    test('legacy entries with no owner stay visible to everyone', () async {
      // Written before OutboxEntry.uid existed; nothing better is knowable and
      // they age out of the grace window within a day and a half.
      await outboxFor(null).add(entry('legacy'));
      expect(await outboxFor('userB').entries(), hasLength(1));
    });

    test('clearAll wipes every account, for deletion only', () async {
      // Account deletion must erase the local outbox: a deleted account's
      // captures can never settle, and they hold the GPS positions of someone
      // who just asked to be erased. Sign-out must NOT — see the test below.
      final a = outboxFor('userA');
      await a.add(entry('a1'));
      await outboxFor('userB').add(entry('b1'));
      await a.setPendingFlushAttemptId('flush-1');

      await a.clearAll();

      expect(await outboxFor('userA').entries(), isEmpty);
      expect(await outboxFor('userB').entries(), isEmpty,
          reason: 'deletion wipes the store, not just the current owner');
      expect(await outboxFor('userA').pendingFlushAttemptId(), isNull,
          reason: 'a replay id for a deleted account is dead weight too');
      expect(a.pendingCount.value, 0);
    });

    test('signing out leaves the captures alone', () async {
      // The counterpart to clearAll: a user who signs out and back in must
      // still be able to flush what they banked. Only the COUNT goes to zero
      // while nobody owns them.
      var uid = 'userA';
      final outbox = ClaimOutbox(uidProvider: () => uid);
      await outbox.add(entry('a1'));

      uid = 'signed-out';
      await outbox.refreshOwnership();
      expect(outbox.pendingCount.value, 0);

      uid = 'userA';
      expect(await outbox.entries(), hasLength(1),
          reason: 'sign-out must not destroy banked claims');
    });

    test('refreshOwnership recounts after the signed-in user changes',
        () async {
      var uid = 'userA';
      final outbox = ClaimOutbox(uidProvider: () => uid);
      await outbox.add(entry('a1'));
      expect(outbox.pendingCount.value, 1);

      uid = 'userB';
      await outbox.refreshOwnership();
      expect(outbox.pendingCount.value, 0);

      uid = 'userA';
      await outbox.refreshOwnership();
      expect(outbox.pendingCount.value, 1);
    });
  });
}
