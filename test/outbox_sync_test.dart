// Unit tests for OutboxSync (ROADMAP v1.5, offline play Phase 3).
//
// The sync flushes banked captures through the flushOfflineClaims callable
// and reconciles the per-item verdicts honestly: settled entries (claimed OR
// permanently rejected) leave the outbox; transient outcomes (transport
// failure, quota exhausted today) stay banked for the next attempt.

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/services/claim_outbox.dart';
import 'package:postbox_game/services/outbox_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeResult<T> implements HttpsCallableResult<T> {
  _FakeResult(this.data);
  @override
  final T data;
}

class _FakeFunctionsException extends FirebaseFunctionsException {
  _FakeFunctionsException({required super.code, required super.message});
}

OutboxEntry _entry(String id, {int? wallMs}) => OutboxEntry(
      scanId: 'tok-$id',
      lat: 51.5,
      lng: -0.12,
      // Recent by default so pruneExpired (grace window) keeps the entry.
      capturedWallMs:
          wallMs ?? DateTime.now().millisecondsSinceEpoch - 60000,
      capturedMonotonicMs: 0,
      attemptId: id,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ClaimOutbox.resetForTest();
  });

  test('a fully-successful flush empties the outbox and sums the outcome', () async {
    final outbox = ClaimOutbox.instance;
    await outbox.add(_entry('a1'));
    await outbox.add(_entry('a2'));

    Map<String, dynamic>? payload;
    final sync = OutboxSync(
      outbox: outbox,
      callable: (p) async {
        payload = p;
        return _FakeResult<dynamic>({
          'results': [
            {'ok': true, 'claimed': 1, 'points': 7, 'dailyDate': '2026-07-20'},
            {'ok': true, 'claimed': 1, 'points': 2, 'dailyDate': '2026-07-20'},
          ],
          'totalClaimed': 2,
          'totalPoints': 9,
        });
      },
      graceHoursProvider: () => 36,
    );

    final summary = await sync.flushNow();
    expect(summary, isNotNull);
    expect(summary!.claimed, 2);
    expect(summary.points, 9);
    expect(summary.rejected, 0);
    expect(outbox.pendingCount.value, 0);

    expect(payload!['claims'], hasLength(2));
    final first = (payload!['claims'] as List).first as Map;
    expect(first['scanId'], 'tok-a1');
    expect(first['capturedAtMs'], isA<int>());
    expect(payload!['flushClientTsMs'], isA<int>());
    expect(payload!['attemptId'], isA<String>());
  });

  test('permanent rejections leave the outbox; transient ones stay banked', () async {
    final outbox = ClaimOutbox.instance;
    await outbox.add(_entry('ok1'));
    await outbox.add(_entry('dead1'));
    await outbox.add(_entry('quota1'));

    final sync = OutboxSync(
      outbox: outbox,
      callable: (_) async => _FakeResult<dynamic>({
        'results': [
          {'ok': true, 'claimed': 1, 'points': 4, 'dailyDate': '2026-07-20'},
          {'ok': false, 'reason': 'expired'},
          {'ok': false, 'reason': 'quota_exceeded'},
        ],
        'totalClaimed': 1,
        'totalPoints': 4,
      }),
      graceHoursProvider: () => 36,
    );

    final summary = await sync.flushNow();
    expect(summary!.claimed, 1);
    expect(summary.rejected, 1);
    expect(summary.kept, 1);
    final left = await outbox.entries();
    expect(left.map((e) => e.attemptId), ['quota1'],
        reason: 'quota-limited captures retry another day; expired ones never can');
  });

  test('a transport failure keeps everything banked and reports nothing', () async {
    final outbox = ClaimOutbox.instance;
    await outbox.add(_entry('a1'));

    final sync = OutboxSync(
      outbox: outbox,
      callable: (_) async =>
          throw _FakeFunctionsException(code: 'unavailable', message: 'down'),
      graceHoursProvider: () => 36,
      maxAutoRetries: 0,
    );

    final summary = await sync.flushNow();
    expect(summary, isNull);
    expect(outbox.pendingCount.value, 1);
  });

  test('an empty outbox is a no-op', () async {
    var calls = 0;
    final sync = OutboxSync(
      outbox: ClaimOutbox.instance,
      callable: (_) async {
        calls++;
        return _FakeResult<dynamic>({'results': []});
      },
      graceHoursProvider: () => 36,
    );
    expect(await sync.flushNow(), isNull);
    expect(calls, 0);
  });

  test('the flush attemptId is stable while the batch head is unchanged', () async {
    final outbox = ClaimOutbox.instance;
    await outbox.add(_entry('a1'));
    final ids = <String>[];
    final sync = OutboxSync(
      outbox: outbox,
      callable: (p) async {
        ids.add(p['attemptId'] as String);
        throw _FakeFunctionsException(code: 'unavailable', message: 'down');
      },
      graceHoursProvider: () => 36,
      maxAutoRetries: 0,
    );
    await sync.flushNow();
    await sync.flushNow();
    expect(ids, hasLength(2));
    expect(ids[0], ids[1],
        reason: 'a retried flush must replay, not re-adjudicate + double-spend quota');
  });

  test('concurrent flushNow calls do not double-send', () async {
    final outbox = ClaimOutbox.instance;
    await outbox.add(_entry('a1'));
    var calls = 0;
    final sync = OutboxSync(
      outbox: outbox,
      callable: (_) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return _FakeResult<dynamic>({
          'results': [
            {'ok': true, 'claimed': 1, 'points': 2, 'dailyDate': '2026-07-20'},
          ],
        });
      },
      graceHoursProvider: () => 36,
    );
    final results = await Future.wait([sync.flushNow(), sync.flushNow()]);
    expect(calls, 1);
    expect(results.where((r) => r != null), hasLength(1));
  });
}
