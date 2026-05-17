import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';

/// Read-only wrapper around Firebase Remote Config.
///
/// Owns the defaults map (single source of truth alongside the typed getters
/// below), wires the fetch lifecycle once at app start, and exposes one
/// typed getter per flag so call sites never see raw keys.
///
/// The first slice ships three flags:
/// - [killSwitchRouteMode]    — hide Route Mode without a release.
/// - [killSwitchReporting]    — hide problem-reporting entry points.
/// - [jamesWelcomeVariant]    — A/B copy variant for James's first-launch line.
///
/// Defaults match today's shipped behaviour so the app degrades to the current
/// experience if Remote Config never resolves.
class RemoteConfigService {
  RemoteConfigService({FirebaseRemoteConfig? remoteConfig})
      : _rc = remoteConfig ?? FirebaseRemoteConfig.instance;

  final FirebaseRemoteConfig _rc;

  /// Process-wide accessor. The first read constructs an instance backed by
  /// `FirebaseRemoteConfig.instance`; tests can substitute a fake via the
  /// setter before any call site reads it. Nullable backing field so the
  /// setter never triggers the production-default initializer.
  static RemoteConfigService? _instance;
  static RemoteConfigService get instance =>
      _instance ??= RemoteConfigService();

  @visibleForTesting
  static set instance(RemoteConfigService value) {
    _instance = value;
  }

  @visibleForTesting
  static void resetForTest() {
    _instance = null;
  }

  static const String keyKillSwitchRouteMode = 'kill_switch_route_mode';
  static const String keyKillSwitchReporting = 'kill_switch_reporting';
  static const String keyJamesWelcomeVariant = 'james_welcome_variant';

  static const String welcomeVariantClassic = 'classic';
  static const String welcomeVariantCheeky = 'cheeky';

  /// Defaults are the source of truth for both registration with the plugin
  /// and for the admin debug screen. Keep types stable — the plugin coerces
  /// based on the registered default's type.
  static const Map<String, Object> defaults = <String, Object>{
    keyKillSwitchRouteMode: false,
    keyKillSwitchReporting: false,
    keyJamesWelcomeVariant: welcomeVariantClassic,
  };

  static const Duration _fetchTimeout = Duration(seconds: 10);
  static const Duration _releaseMinInterval = Duration(hours: 1);

  /// Best-effort one-time setup. Safe to await but typically fired-and-forgotten
  /// from `main()` so the splash doesn't block on the network round-trip —
  /// defaults serve immediately and remote values activate when the fetch
  /// resolves.
  Future<void> init() async {
    try {
      await _rc.setConfigSettings(RemoteConfigSettings(
        fetchTimeout: _fetchTimeout,
        minimumFetchInterval: kDebugMode ? Duration.zero : _releaseMinInterval,
      ));
      await _rc.setDefaults(defaults);
      await _rc.fetchAndActivate();
    } catch (e, st) {
      debugPrint('RemoteConfigService.init failed: $e\n$st');
    }
  }

  bool get killSwitchRouteMode => _rc.getBool(keyKillSwitchRouteMode);
  bool get killSwitchReporting => _rc.getBool(keyKillSwitchReporting);
  String get jamesWelcomeVariant => _rc.getString(keyJamesWelcomeVariant);

  RemoteConfigFetchStatus get lastFetchStatus => _rc.lastFetchStatus;
  DateTime get lastFetchTime => _rc.lastFetchTime;

  /// Force a fresh fetch ignoring the minimum-interval throttle. Restores the
  /// release interval afterwards so subsequent normal calls still throttle.
  /// Used by the admin debug screen.
  Future<bool> forceRefresh() async {
    try {
      await _rc.setConfigSettings(RemoteConfigSettings(
        fetchTimeout: _fetchTimeout,
        minimumFetchInterval: Duration.zero,
      ));
      final activated = await _rc.fetchAndActivate();
      if (!kDebugMode) {
        await _rc.setConfigSettings(RemoteConfigSettings(
          fetchTimeout: _fetchTimeout,
          minimumFetchInterval: _releaseMinInterval,
        ));
      }
      return activated;
    } catch (e, st) {
      debugPrint('RemoteConfigService.forceRefresh failed: $e\n$st');
      return false;
    }
  }

  /// Snapshot of every known flag plus its current value and source. The admin
  /// debug screen renders this directly — order matches [defaults].
  List<RemoteConfigEntry> snapshot() {
    final all = _rc.getAll();
    return [
      for (final entry in defaults.entries)
        RemoteConfigEntry(
          key: entry.key,
          value: _resolveValue(entry.key, entry.value),
          defaultValue: entry.value,
          source: all[entry.key]?.source ?? ValueSource.valueStatic,
        ),
    ];
  }

  Object _resolveValue(String key, Object def) {
    if (def is bool) return _rc.getBool(key);
    if (def is int) return _rc.getInt(key);
    if (def is double) return _rc.getDouble(key);
    return _rc.getString(key);
  }
}

/// Row payload for the admin debug screen.
class RemoteConfigEntry {
  const RemoteConfigEntry({
    required this.key,
    required this.value,
    required this.defaultValue,
    required this.source,
  });

  final String key;
  final Object value;
  final Object defaultValue;
  final ValueSource source;

  bool get usingDefault =>
      source == ValueSource.valueDefault || source == ValueSource.valueStatic;
}
