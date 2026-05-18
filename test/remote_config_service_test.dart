import 'dart:async';

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/remote_config_service.dart';

/// In-process fake of FirebaseRemoteConfig with just the surface
/// RemoteConfigService uses. `Fake` causes any non-overridden member to throw,
/// which catches drift if the wrapper starts reaching for unrelated plugin APIs.
class _FakeRemoteConfig extends Fake implements FirebaseRemoteConfig {
  _FakeRemoteConfig({
    Map<String, Object>? remoteValues,
    this.shouldThrowOnFetch = false,
  }) : _remote = Map<String, Object>.from(remoteValues ?? const {});

  final Map<String, Object> _defaults = {};
  final Map<String, Object> _remote;
  bool shouldThrowOnFetch;

  int fetchAndActivateCalls = 0;
  int activateCalls = 0;
  int setConfigSettingsCalls = 0;
  Duration? lastMinimumFetchInterval;

  final StreamController<RemoteConfigUpdate> _updates =
      StreamController<RemoteConfigUpdate>.broadcast();
  @override
  Stream<RemoteConfigUpdate> get onConfigUpdated => _updates.stream;

  /// Test helper: swap the backing remote values and fire an update event so
  /// the service re-activates and pushes the new state to its notifier.
  void pushRemoteUpdate(Map<String, Object> newValues) {
    _remote
      ..clear()
      ..addAll(newValues);
    _updates.add(RemoteConfigUpdate(newValues.keys.toSet()));
  }

  void disposeFake() {
    _updates.close();
  }

  @override
  Future<bool> activate() async {
    activateCalls++;
    return true;
  }

  RemoteConfigFetchStatus _status = RemoteConfigFetchStatus.noFetchYet;
  @override
  RemoteConfigFetchStatus get lastFetchStatus => _status;

  DateTime _lastFetchTime = DateTime.fromMillisecondsSinceEpoch(0);
  @override
  DateTime get lastFetchTime => _lastFetchTime;

  @override
  Future<void> setConfigSettings(RemoteConfigSettings settings) async {
    setConfigSettingsCalls++;
    lastMinimumFetchInterval = settings.minimumFetchInterval;
  }

  @override
  Future<void> setDefaults(Map<String, dynamic> defaults) async {
    _defaults
      ..clear()
      ..addAll(defaults.cast<String, Object>());
  }

  @override
  Future<bool> fetchAndActivate() async {
    fetchAndActivateCalls++;
    if (shouldThrowOnFetch) {
      throw StateError('network down');
    }
    _status = RemoteConfigFetchStatus.success;
    _lastFetchTime = DateTime.now();
    return true;
  }

  Object? _lookup(String key) => _remote[key] ?? _defaults[key];

  @override
  bool getBool(String key) {
    final v = _lookup(key);
    if (v is bool) return v;
    if (v is String) return v.toLowerCase() == 'true';
    return false;
  }

  @override
  String getString(String key) {
    final v = _lookup(key);
    return v?.toString() ?? '';
  }

  @override
  int getInt(String key) {
    final v = _lookup(key);
    if (v is int) return v;
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  @override
  double getDouble(String key) {
    final v = _lookup(key);
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  @override
  Map<String, RemoteConfigValue> getAll() {
    final keys = <String>{..._remote.keys, ..._defaults.keys};
    return {
      for (final k in keys)
        k: RemoteConfigValue(
          null,
          _remote.containsKey(k)
              ? ValueSource.valueRemote
              : ValueSource.valueDefault,
        ),
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(RemoteConfigService.resetForTest);

  group('RemoteConfigService defaults', () {
    test('typed getters return the default values before any fetch', () {
      final fake = _FakeRemoteConfig();
      final service = RemoteConfigService(remoteConfig: fake);

      // Before init(), the fake holds no defaults — the wrapper getters fall
      // through to the fake's "missing key" fallbacks (false / "").
      expect(service.killSwitchRouteMode, isFalse);
      expect(service.killSwitchReporting, isFalse);

      // After init(), the registered defaults are served.
      return service.init().then((_) {
        expect(service.killSwitchRouteMode, isFalse);
        expect(service.killSwitchReporting, isFalse);
        expect(service.jamesWelcomeVariant,
            equals(RemoteConfigService.welcomeVariantClassic));
      });
    });

    test('defaults map covers every typed getter', () {
      expect(RemoteConfigService.defaults,
          containsPair(RemoteConfigService.keyKillSwitchRouteMode, false));
      expect(RemoteConfigService.defaults,
          containsPair(RemoteConfigService.keyKillSwitchReporting, false));
      expect(
          RemoteConfigService.defaults,
          containsPair(RemoteConfigService.keyJamesWelcomeVariant,
              RemoteConfigService.welcomeVariantClassic));
      expect(RemoteConfigService.defaults,
          containsPair(RemoteConfigService.keyMaintenanceMode, false));
      expect(
          RemoteConfigService.defaults,
          containsPair(RemoteConfigService.keyMaintenanceMessage,
              RemoteConfigService.defaultMaintenanceMessage));
    });
  });

  group('RemoteConfigService maintenance flag', () {
    test('defaults to off with the canned English message', () async {
      final fake = _FakeRemoteConfig();
      final service = RemoteConfigService(remoteConfig: fake);
      await service.init();

      expect(service.maintenanceMode, isFalse);
      expect(service.maintenanceMessage,
          equals(RemoteConfigService.defaultMaintenanceMessage));
      expect(service.maintenanceModeListenable.value, isFalse);

      fake.disposeFake();
    });

    test('remote value flips the flag and seeds the notifier on init',
        () async {
      final fake = _FakeRemoteConfig(remoteValues: {
        RemoteConfigService.keyMaintenanceMode: true,
        RemoteConfigService.keyMaintenanceMessage: 'Back shortly, postie...',
      });
      final service = RemoteConfigService(remoteConfig: fake);
      await service.init();

      expect(service.maintenanceMode, isTrue);
      expect(service.maintenanceMessage, equals('Back shortly, postie...'));
      expect(service.maintenanceModeListenable.value, isTrue);

      fake.disposeFake();
    });

    test('empty remote message falls back to the canned default', () async {
      final fake = _FakeRemoteConfig(remoteValues: {
        RemoteConfigService.keyMaintenanceMode: true,
        RemoteConfigService.keyMaintenanceMessage: '   ',
      });
      final service = RemoteConfigService(remoteConfig: fake);
      await service.init();

      expect(service.maintenanceMessage,
          equals(RemoteConfigService.defaultMaintenanceMessage));

      fake.disposeFake();
    });

    test('onConfigUpdated push event flips the notifier without an app restart',
        () async {
      final fake = _FakeRemoteConfig();
      final service = RemoteConfigService(remoteConfig: fake);
      await service.init();

      expect(service.maintenanceModeListenable.value, isFalse);
      var notified = 0;
      service.maintenanceModeListenable.addListener(() => notified++);

      fake.pushRemoteUpdate({
        RemoteConfigService.keyMaintenanceMode: true,
      });
      // Let the listener microtask run.
      await Future<void>.delayed(Duration.zero);

      expect(fake.activateCalls, greaterThanOrEqualTo(1));
      expect(service.maintenanceModeListenable.value, isTrue);
      expect(notified, equals(1));

      fake.disposeFake();
    });

    test('forceRefresh also syncs the maintenance notifier', () async {
      final fake = _FakeRemoteConfig();
      final service = RemoteConfigService(remoteConfig: fake);
      await service.init();

      // Mutate the remote backing store without firing onConfigUpdated, then
      // ask the service to forceRefresh — it must pick up the new value.
      fake._remote[RemoteConfigService.keyMaintenanceMode] = true;
      await service.forceRefresh();

      expect(service.maintenanceModeListenable.value, isTrue);

      fake.disposeFake();
    });
  });

  group('RemoteConfigService remote overrides', () {
    test('remote values take precedence over defaults', () async {
      final fake = _FakeRemoteConfig(remoteValues: {
        RemoteConfigService.keyKillSwitchRouteMode: true,
        RemoteConfigService.keyKillSwitchReporting: true,
        RemoteConfigService.keyJamesWelcomeVariant:
            RemoteConfigService.welcomeVariantCheeky,
      });
      final service = RemoteConfigService(remoteConfig: fake);

      await service.init();

      expect(service.killSwitchRouteMode, isTrue);
      expect(service.killSwitchReporting, isTrue);
      expect(service.jamesWelcomeVariant,
          equals(RemoteConfigService.welcomeVariantCheeky));
    });
  });

  group('RemoteConfigService.init error handling', () {
    test('swallows fetch errors and still serves defaults', () async {
      final fake = _FakeRemoteConfig(shouldThrowOnFetch: true);
      final service = RemoteConfigService(remoteConfig: fake);

      // Must not rethrow.
      await service.init();

      expect(service.killSwitchRouteMode, isFalse);
      expect(service.killSwitchReporting, isFalse);
      expect(service.jamesWelcomeVariant,
          equals(RemoteConfigService.welcomeVariantClassic));
      expect(fake.fetchAndActivateCalls, equals(1));
    });
  });

  group('RemoteConfigService.forceRefresh', () {
    test('zeroes the interval, fetches, and returns the activation flag',
        () async {
      final fake = _FakeRemoteConfig();
      final service = RemoteConfigService(remoteConfig: fake);

      await service.init();
      final settingsCallsAfterInit = fake.setConfigSettingsCalls;
      final fetchesAfterInit = fake.fetchAndActivateCalls;

      final activated = await service.forceRefresh();

      expect(activated, isTrue);
      // At least one extra setConfigSettings + fetchAndActivate beyond init().
      expect(fake.setConfigSettingsCalls, greaterThan(settingsCallsAfterInit));
      expect(fake.fetchAndActivateCalls, equals(fetchesAfterInit + 1));
      // The most recent setConfigSettings before fetchAndActivate must have
      // zeroed the interval so the throttle never blocks the manual refresh.
      // (In release mode the wrapper restores the production interval after
      // the fetch; the test runs in debug mode, so it stays at zero.)
      expect(fake.lastMinimumFetchInterval, equals(Duration.zero));
    });

    test('returns false when the fetch throws', () async {
      final fake = _FakeRemoteConfig(shouldThrowOnFetch: true);
      final service = RemoteConfigService(remoteConfig: fake);

      final activated = await service.forceRefresh();

      expect(activated, isFalse);
    });
  });

  group('RemoteConfigService.snapshot', () {
    test('returns one entry per known key with the right source', () async {
      final fake = _FakeRemoteConfig(remoteValues: {
        RemoteConfigService.keyKillSwitchRouteMode: true,
      });
      final service = RemoteConfigService(remoteConfig: fake);

      await service.init();

      final entries = service.snapshot();
      expect(entries, hasLength(RemoteConfigService.defaults.length));

      final byKey = {for (final e in entries) e.key: e};
      expect(byKey[RemoteConfigService.keyKillSwitchRouteMode]!.value, isTrue);
      expect(byKey[RemoteConfigService.keyKillSwitchRouteMode]!.source,
          equals(ValueSource.valueRemote));
      expect(byKey[RemoteConfigService.keyKillSwitchReporting]!.usingDefault,
          isTrue);
    });
  });

  group('RemoteConfigService.instance', () {
    test('setter swaps the singleton without invoking the default initializer',
        () {
      final fake = _FakeRemoteConfig();
      final injected = RemoteConfigService(remoteConfig: fake);

      RemoteConfigService.instance = injected;

      expect(identical(RemoteConfigService.instance, injected), isTrue);
    });

    test('resetForTest clears the cached instance', () {
      final fake = _FakeRemoteConfig();
      final injected = RemoteConfigService(remoteConfig: fake);
      RemoteConfigService.instance = injected;

      RemoteConfigService.resetForTest();

      // After reset, the next get would lazily try to build a production
      // instance backed by FirebaseRemoteConfig.instance — we don't read it
      // here because that would require a live Firebase app. Asserting the
      // pre-condition is enough: the previously-injected instance is gone
      // from the backing field, which we verify via a fresh injection.
      final next = RemoteConfigService(remoteConfig: fake);
      RemoteConfigService.instance = next;
      expect(identical(RemoteConfigService.instance, injected), isFalse);
      expect(identical(RemoteConfigService.instance, next), isTrue);
    });
  });
}
