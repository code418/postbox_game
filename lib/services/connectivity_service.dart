// Connectivity awareness (ROADMAP v1.5, offline play Phase 1).
//
// Before v1.5 the app inferred "offline" only from
// FirebaseFunctionsException.code == 'unavailable' at individual call sites.
// This service gives the app one authoritative, listenable answer, driving
// the OfflineBanner (home.dart) and the outbox flush trigger
// (outbox_sync.dart).
//
// `online` is OPTIMISTIC (starts true, fails open): connectivity_plus reports
// link-layer state, which can never prove the backend is reachable — the
// callables' own error handling stays the ground truth. Treat `online ==
// false` as "definitely offline, adjust UX" and `true` as "probably fine".

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

class ConnectivityService {
  ConnectivityService({
    Future<List<ConnectivityResult>> Function()? check,
    Stream<List<ConnectivityResult>>? changes,
  })  : _check = check ?? (() => Connectivity().checkConnectivity()),
        _changes = changes ?? Connectivity().onConnectivityChanged;

  final Future<List<ConnectivityResult>> Function() _check;
  final Stream<List<ConnectivityResult>> _changes;
  StreamSubscription<List<ConnectivityResult>>? _sub;

  /// Process-wide accessor, same pattern as RemoteConfigService: tests
  /// substitute an injected instance via the setter before first read.
  static ConnectivityService? _instance;
  static ConnectivityService get instance => _instance ??= ConnectivityService();

  @visibleForTesting
  static set instance(ConnectivityService value) => _instance = value;

  @visibleForTesting
  static void resetForTest() {
    _instance?._sub?.cancel();
    _instance = null;
  }

  /// True while the device reports any usable network transport. Optimistic
  /// default (true) so nothing degrades before the first check resolves.
  final ValueNotifier<bool> _online = ValueNotifier<bool>(true);
  ValueListenable<bool> get online => _online;

  static bool _isOnline(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);

  /// Reads the current state and subscribes to updates. Safe to call more
  /// than once; errors fail open (stay online — see class comment).
  Future<void> init() async {
    await _sub?.cancel();
    _sub = _changes.listen(
      (results) => _online.value = _isOnline(results),
      onError: (_) => _online.value = true,
    );
    try {
      _online.value = _isOnline(await _check());
    } catch (_) {
      _online.value = true;
    }
  }
}
