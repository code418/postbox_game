import 'dart:async';
import 'dart:convert';

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';

import 'package:postbox_game/app_preferences.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/services/crashlytics_helper.dart';

/// Read-only wrapper around Firebase Remote Config.
///
/// Owns the defaults map (single source of truth alongside the typed getters
/// below), wires the fetch lifecycle once at app start, and exposes one
/// typed getter per flag so call sites never see raw keys.
///
/// Flags currently shipped:
/// - [killSwitchRouteMode]    — hide Route Mode without a release.
/// - [killSwitchReporting]    — hide problem-reporting entry points.
/// - [jamesWelcomeVariant]    — A/B copy variant for James's first-launch line.
/// - [maintenanceMode]        — flip the app into read-only mode (banner +
///                              every write entry-point refuses with a toast).
/// - [maintenanceMessage]     — admin-authored banner copy shown while
///                              [maintenanceMode] is on.
///
/// Defaults match today's shipped behaviour so the app degrades to the current
/// experience if Remote Config never resolves.
class RemoteConfigService {
  RemoteConfigService({FirebaseRemoteConfig? remoteConfig})
      : _rc = remoteConfig ?? FirebaseRemoteConfig.instance {
    _maintenanceMode = ValueNotifier<bool>(_rc.getBool(keyMaintenanceMode));
  }

  final FirebaseRemoteConfig _rc;
  late final ValueNotifier<bool> _maintenanceMode;
  StreamSubscription<RemoteConfigUpdate>? _updateSub;

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
  static const String keyMaintenanceMode = 'maintenance_mode';
  static const String keyMaintenanceMessage = 'maintenance_message';
  static const String keyClaimRadiusMeters = 'claim_radius_meters';
  static const String keyPointsByMonarch = 'points_by_monarch';

  static const String welcomeVariantClassic = 'classic';
  static const String welcomeVariantCheeky = 'cheeky';

  /// Safety band for a Remote-Config-supplied claim radius (metres). Values
  /// outside this band are treated as misconfiguration and ignored (fall back
  /// to [AppPreferences.claimRadiusMeters]). Mirrors _config.ts on the server.
  static const double minClaimRadiusMeters = 10.0;
  static const double maxClaimRadiusMeters = 100.0;

  /// Safety band for a Remote-Config-supplied per-monarch point value.
  static const int minMonarchPoints = 1;
  static const int maxMonarchPoints = 50;

  /// Default `points_by_monarch` JSON. MUST equal [MonarchInfo.points] — pinned
  /// by test/cross_language_sync_test.dart. Remote Config only overrides on top.
  static const String defaultPointsByMonarchJson =
      '{"EIIR":2,"CIIIR":9,"GR":4,"GVR":4,"GVIR":4,"VR":7,"EVIIR":9,'
      '"EVIIIR":12,"SCOTTISH_CROWN":4}';

  /// Default banner copy when no remote string is set. James voice, no em-dash.
  static const String defaultMaintenanceMessage =
      "The Royal Mail van's pulled in for a service. "
      'Have a browse around for a bit, postie...';

  /// Defaults are the source of truth for both registration with the plugin
  /// and for the admin debug screen. Keep types stable — the plugin coerces
  /// based on the registered default's type.
  static const Map<String, Object> defaults = <String, Object>{
    keyKillSwitchRouteMode: false,
    keyKillSwitchReporting: false,
    keyJamesWelcomeVariant: welcomeVariantClassic,
    keyMaintenanceMode: false,
    keyMaintenanceMessage: defaultMaintenanceMessage,
    keyClaimRadiusMeters: AppPreferences.claimRadiusMeters,
    keyPointsByMonarch: defaultPointsByMonarchJson,
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
      _syncMaintenanceMode();
      _subscribeToConfigUpdates();
    } catch (e, st) {
      debugPrint('RemoteConfigService.init failed: $e\n$st');
    }
  }

  /// Push-channel subscription so a flag flipped on the Firebase console
  /// reaches foregrounded clients in seconds rather than waiting out the
  /// 1-hour minimum fetch interval. Failures are swallowed — the app still
  /// works on cached values.
  void _subscribeToConfigUpdates() {
    _updateSub?.cancel();
    try {
      _updateSub = _rc.onConfigUpdated.listen((_) async {
        try {
          await _rc.activate();
          _syncMaintenanceMode();
        } catch (e, st) {
          debugPrint('RemoteConfigService activate-on-update failed: $e\n$st');
        }
      }, onError: (Object e, StackTrace st) {
        debugPrint('RemoteConfigService onConfigUpdated error: $e\n$st');
      });
    } catch (e, st) {
      // Some test fakes / older plugin versions may not expose the stream.
      debugPrint('RemoteConfigService onConfigUpdated unavailable: $e\n$st');
    }
  }

  void _syncMaintenanceMode() {
    // Crash context: when Remote Config last resolved (helps spot clients stuck
    // on stale config). Runs after every fetch/activate that calls this.
    CrashlyticsHelper.setContext(CrashlyticsHelper.keyRemoteConfigFetchTs,
        _rc.lastFetchTime.toIso8601String());
    final v = _rc.getBool(keyMaintenanceMode);
    if (_maintenanceMode.value != v) {
      _maintenanceMode.value = v;
    }
  }

  bool get killSwitchRouteMode => _rc.getBool(keyKillSwitchRouteMode);
  bool get killSwitchReporting => _rc.getBool(keyKillSwitchReporting);
  String get jamesWelcomeVariant => _rc.getString(keyJamesWelcomeVariant);
  bool get maintenanceMode => _rc.getBool(keyMaintenanceMode);
  String get maintenanceMessage {
    final raw = _rc.getString(keyMaintenanceMessage).trim();
    return raw.isEmpty ? defaultMaintenanceMessage : raw;
  }

  /// Claim radius (metres), Remote-Config-driven with a safety band. An unset,
  /// non-finite, or out-of-band remote value falls back to the hard-coded
  /// [AppPreferences.claimRadiusMeters].
  double get claimRadiusMeters {
    final raw = _rc.getDouble(keyClaimRadiusMeters);
    if (!raw.isFinite ||
        raw < minClaimRadiusMeters ||
        raw > maxClaimRadiusMeters) {
      return AppPreferences.claimRadiusMeters;
    }
    return raw;
  }

  /// Points for [cipher]: the Remote-Config override if valid + present, else
  /// the hard-coded [MonarchInfo.getPoints] fallback.
  int pointsForCipher(String cipher) {
    final override = _parsePointsOverride(_rc.getString(keyPointsByMonarch));
    final v = override?[cipher];
    return v ?? MonarchInfo.getPoints(cipher);
  }

  /// The full per-monarch point map: [MonarchInfo.points] with any valid
  /// Remote-Config overrides layered on top.
  Map<String, int> get pointsByMonarch {
    final override = _parsePointsOverride(_rc.getString(keyPointsByMonarch));
    if (override == null) return Map<String, int>.from(MonarchInfo.points);
    return <String, int>{...MonarchInfo.points, ...override};
  }

  /// Parse+validate the `points_by_monarch` JSON. Returns a map of recognised
  /// monarch -> points (integers in [[minMonarchPoints], [maxMonarchPoints]]);
  /// unknown keys are dropped. Returns null (=> use hard-coded points wholesale)
  /// if the string is absent, not a JSON object, or ANY value is a non-integer
  /// / out of range. Mirrors parsePointsOverride in functions/src/_config.ts.
  Map<String, int>? _parsePointsOverride(String raw) {
    if (raw.trim().isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final out = <String, int>{};
    for (final entry in decoded.entries) {
      final key = entry.key;
      if (key is! String || !MonarchInfo.points.containsKey(key)) {
        continue; // drop unknown keys
      }
      final value = entry.value;
      if (value is! int) return null; // wholesale reject non-integers
      if (value < minMonarchPoints || value > maxMonarchPoints) return null;
      out[key] = value;
    }
    return out;
  }

  /// UI subscribes to this to rebuild when the maintenance flag flips
  /// (via push, force-refresh, or a fresh fetch).
  ValueListenable<bool> get maintenanceModeListenable => _maintenanceMode;

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
      _syncMaintenanceMode();
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
