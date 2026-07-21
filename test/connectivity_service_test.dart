// Unit tests for ConnectivityService (ROADMAP v1.5, offline play Phase 1).
//
// The service wraps connectivity_plus into a ValueListenable<bool> `online`
// that the OfflineBanner and the outbox sync listen to. Both the initial
// check and the update stream are injectable so tests run without the
// platform channel.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/services/connectivity_service.dart';

void main() {
  tearDown(ConnectivityService.resetForTest);

  test('starts online (optimistic) and applies the initial check', () async {
    final service = ConnectivityService(
      check: () async => [ConnectivityResult.none],
      changes: const Stream.empty(),
    );
    expect(service.online.value, isTrue,
        reason: 'optimistic default before the first check resolves');
    await service.init();
    expect(service.online.value, isFalse);
  });

  test('flips offline and back online with stream events', () async {
    final updates = StreamController<List<ConnectivityResult>>();
    addTearDown(updates.close);
    final service = ConnectivityService(
      check: () async => [ConnectivityResult.wifi],
      changes: updates.stream,
    );
    await service.init();
    expect(service.online.value, isTrue);

    updates.add([ConnectivityResult.none]);
    await Future<void>.delayed(Duration.zero);
    expect(service.online.value, isFalse);

    updates.add([ConnectivityResult.mobile]);
    await Future<void>.delayed(Duration.zero);
    expect(service.online.value, isTrue);
  });

  test('notifies listeners exactly on transitions', () async {
    final updates = StreamController<List<ConnectivityResult>>();
    addTearDown(updates.close);
    final service = ConnectivityService(
      check: () async => [ConnectivityResult.wifi],
      changes: updates.stream,
    );
    await service.init();
    var notifications = 0;
    service.online.addListener(() => notifications++);

    updates.add([ConnectivityResult.wifi]); // no transition
    updates.add([ConnectivityResult.none]); // -> offline
    updates.add([ConnectivityResult.none]); // no transition
    updates.add([ConnectivityResult.ethernet]); // -> online
    await Future<void>.delayed(Duration.zero);
    expect(notifications, 2);
  });

  test('a failing initial check leaves the service online (fail-open)', () async {
    final service = ConnectivityService(
      check: () async => throw StateError('no platform'),
      changes: const Stream.empty(),
    );
    await service.init();
    expect(service.online.value, isTrue);
  });
}
