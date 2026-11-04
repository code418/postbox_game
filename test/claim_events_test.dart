// Regression: ClaimHistoryScreen's period tabs are AutomaticKeepAlive inside
// Home's IndexedStack, so they fetch once at app start and keep that answer.
// Reproduced on the emulator: claim a postbox, open History, and it said
// "No claims today — yet. Go find a postbox!" while the leaderboard already
// showed the points. Pull-to-refresh brought the claim in, confirming the data
// was there and only the client's cached future was stale.
//
// ClaimEvents is the invalidation signal; these pin that it actually fires
// from both claim paths.

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/services/claim_events.dart';
import 'package:postbox_game/services/claim_outbox.dart';
import 'package:postbox_game/services/outbox_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeResult<T> implements HttpsCallableResult<T> {
  _FakeResult(this.data);
  @override
  final T data;
}

class _StubRemoteConfig extends Fake implements FirebaseRemoteConfig {
  @override
  bool getBool(String key) => false;
}

OutboxEntry _entry(String id) => OutboxEntry(
      scanId: 'tok-$id',
      lat: 51.5,
      lng: -0.12,
      capturedWallMs: DateTime.now().millisecondsSinceEpoch - 60000,
      capturedMonotonicMs: 0,
      attemptId: id,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ClaimOutbox.resetForTest();
    ClaimEvents.resetForTest();
    RemoteConfigService.instance =
        RemoteConfigService(remoteConfig: _StubRemoteConfig());
  });
  tearDown(RemoteConfigService.resetForTest);

  test('markClaimed bumps the revision and notifies listeners', () {
    var notified = 0;
    void listener() => notified++;
    ClaimEvents.revision.addListener(listener);
    addTearDown(() => ClaimEvents.revision.removeListener(listener));

    final before = ClaimEvents.revision.value;
    ClaimEvents.markClaimed();
    expect(ClaimEvents.revision.value, before + 1);
    expect(notified, 1, reason: 'History refetches off this notification');

    ClaimEvents.markClaimed();
    expect(notified, 2, reason: 'every claim must invalidate, not just the first');
  });

  test('a flush that credits claims signals them', () async {
    final outbox = ClaimOutbox.instance;
    await outbox.add(_entry('a1'));
    final sync = OutboxSync(
      outbox: outbox,
      callable: (_) async => _FakeResult<dynamic>({
        'results': [
          {'ok': true, 'claimed': 1, 'points': 2, 'dailyDate': '2026-07-24'},
        ],
      }),
      graceHoursProvider: () => 36,
      killSwitchProvider: () => false,
    );

    final before = ClaimEvents.revision.value;
    await sync.flushNow();
    expect(ClaimEvents.revision.value, before + 1,
        reason: 'a flushed claim is as real as a live one');
  });

  test('a flush that credits nothing does not signal', () async {
    final outbox = ClaimOutbox.instance;
    await outbox.add(_entry('dead1'));
    final sync = OutboxSync(
      outbox: outbox,
      callable: (_) async => _FakeResult<dynamic>({
        'results': [
          {'ok': false, 'reason': 'expired'},
        ],
      }),
      graceHoursProvider: () => 36,
      killSwitchProvider: () => false,
    );

    final before = ClaimEvents.revision.value;
    await sync.flushNow();
    expect(ClaimEvents.revision.value, before,
        reason: 'rejections must not trigger pointless refetches');
  });
}
