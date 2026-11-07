// Dart side of the read-only Health Connect bridge (workout claims).
//
// The Kotlin plugin (android/app/src/healthconnect/.../HealthConnectPlugin.kt)
// is a thin adapter; every policy decision — which sessions are eligible,
// when to read, what to send to the server — lives in Dart
// (ActivityClaimsService + activity_helpers.dart) where it is unit-testable.
//
// Only the phone-side Android flavours register the plugin. Everywhere else
// (iOS, web, the Wear OS build, widget tests) the channel has no handler, so
// every call maps MissingPluginException to "unsupported" and the feature
// simply never appears.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Health Connect permission strings (must match HealthConnectMapping.kt and
/// the phone/auto manifests).
abstract final class HealthConnectPermissions {
  static const String readExercise = 'android.permission.health.READ_EXERCISE';
  static const String readExerciseRoutes =
      'android.permission.health.READ_EXERCISE_ROUTES';
}

enum HcAvailability { available, notInstalled, updateRequired, unsupported }

/// One exercise session as read from Health Connect (eligible types only —
/// the plugin drops everything that isn't a walk, run or hike).
@immutable
class HcSession {
  const HcSession({
    required this.id,
    required this.type,
    required this.startMs,
    required this.endMs,
    required this.lastModifiedMs,
    required this.originPackage,
    required this.recordingMethod,
  });

  final String id;

  /// "walking" | "running" | "hiking".
  final String type;
  final int startMs;
  final int endMs;
  final int lastModifiedMs;

  /// Package name of the app that recorded it (e.g. com.fitbit.FitbitMobile).
  final String originPackage;

  /// "active" | "automatic" | "manual" | "unknown".
  final String recordingMethod;

  /// Identity of this VERSION of the session: a fitness app that rewrites the
  /// record (late GPS sync) bumps lastModified, which makes it new again.
  String get versionKey => '$id@$lastModifiedMs';

  static HcSession? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final type = raw['type'];
    final start = raw['startMs'];
    final end = raw['endMs'];
    final lm = raw['lastModifiedMs'];
    final origin = raw['originPackage'];
    final rm = raw['recordingMethod'];
    if (id is! String || type is! String || start is! num || end is! num ||
        lm is! num || origin is! String || rm is! String) {
      return null;
    }
    return HcSession(
      id: id,
      type: type,
      startMs: start.toInt(),
      endMs: end.toInt(),
      lastModifiedMs: lm.toInt(),
      originPackage: origin,
      recordingMethod: rm,
    );
  }

  Map<String, Object> toJson() => {
        'id': id,
        'type': type,
        'startMs': startMs,
        'endMs': endMs,
        'lastModifiedMs': lastModifiedMs,
        'originPackage': originPackage,
        'recordingMethod': recordingMethod,
      };
}

/// One GPS fix on a recorded route.
@immutable
class HcRoutePoint {
  const HcRoutePoint(this.tMs, this.lat, this.lng, [this.accuracyM]);
  final int tMs;
  final double lat;
  final double lng;

  /// Horizontal accuracy in metres, when the recording app supplied one.
  final double? accuracyM;
}

/// The outcome of reading a session's route.
sealed class HcRouteResult {
  const HcRouteResult();
}

class HcRouteData extends HcRouteResult {
  const HcRouteData(this.points);
  final List<HcRoutePoint> points;
}

/// Health Connect wants a per-session OK from the user (route access is set
/// to "Ask every time"). Only an interactive check may prompt.
class HcRouteConsentRequired extends HcRouteResult {
  const HcRouteConsentRequired();
}

/// The session has no GPS route (indoor, phone left at home, not synced).
class HcRouteNoData extends HcRouteResult {
  const HcRouteNoData();
}

/// The user declined the per-session route prompt.
class HcRouteDenied extends HcRouteResult {
  const HcRouteDenied();
}

/// Per-session consent isn't available on this Health Connect version.
class HcRouteUnsupported extends HcRouteResult {
  const HcRouteUnsupported();
}

/// The bridge's contract. Tests implement this directly.
abstract class HealthConnectBridge {
  /// Cheap synchronous platform check (Android phone build). False means the
  /// feature never shows; true still needs [availability] to confirm.
  bool get isSupportedPlatform;
  Future<HcAvailability> availability();
  Future<Set<String>> grantedPermissions();
  Future<Set<String>> requestPermissions();
  Future<List<HcSession>> readSessions({required int sinceMs, required int untilMs});
  Future<HcRouteResult> readRoute(String id);
  Future<HcRouteResult> requestRouteConsent(String id);
  Future<bool> openSettings();
  Future<bool> openInstall();
  Future<void> revokeAll();
}

/// Thrown when the platform side reports a failure the caller should surface
/// (as opposed to "unsupported", which callers treat as feature-absent).
class HealthConnectException implements Exception {
  HealthConnectException(this.code, [this.message]);
  final String code;
  final String? message;
  @override
  String toString() => 'HealthConnectException($code, $message)';
}

class MethodChannelHealthConnectBridge implements HealthConnectBridge {
  MethodChannelHealthConnectBridge({
    MethodChannel? channel,
    bool Function()? isSupportedPlatform,
  })  : _channel = channel ?? const MethodChannel(channelName),
        _isSupportedPlatform = isSupportedPlatform ?? _defaultSupported;

  static const String channelName = 'com.code418.postbox_game/health_connect';

  final MethodChannel _channel;
  final bool Function() _isSupportedPlatform;

  static bool _defaultSupported() =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  bool get isSupportedPlatform => _isSupportedPlatform();

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      throw HealthConnectException('unsupported');
    } on PlatformException catch (e) {
      throw HealthConnectException(e.code, e.message);
    }
  }

  @override
  Future<HcAvailability> availability() async {
    if (!_isSupportedPlatform()) return HcAvailability.unsupported;
    try {
      final m = await _invoke<Map<Object?, Object?>>('getStatus');
      return switch (m?['status']) {
        'available' => HcAvailability.available,
        'not_installed' => HcAvailability.notInstalled,
        'update_required' => HcAvailability.updateRequired,
        _ => HcAvailability.unsupported,
      };
    } on HealthConnectException {
      return HcAvailability.unsupported;
    }
  }

  Set<String> _perms(List<Object?>? raw) =>
      (raw ?? const []).whereType<String>().toSet();

  @override
  Future<Set<String>> grantedPermissions() async {
    if (!_isSupportedPlatform()) return const {};
    try {
      return _perms(await _invoke<List<Object?>>('getGrantedPermissions'));
    } on HealthConnectException catch (e) {
      if (e.code == 'unsupported' || e.code == 'unavailable') return const {};
      rethrow;
    }
  }

  @override
  Future<Set<String>> requestPermissions() async {
    if (!_isSupportedPlatform()) return const {};
    return _perms(await _invoke<List<Object?>>('requestPermissions'));
  }

  @override
  Future<List<HcSession>> readSessions({required int sinceMs, required int untilMs}) async {
    final raw = await _invoke<List<Object?>>(
        'readSessions', {'sinceMs': sinceMs, 'untilMs': untilMs});
    return (raw ?? const [])
        .map(HcSession.tryParse)
        .whereType<HcSession>()
        .toList();
  }

  HcRouteResult _route(Map<Object?, Object?>? m) {
    switch (m?['status']) {
      case 'data':
        final t = m!['t'];
        final lat = m['lat'];
        final lng = m['lng'];
        final acc = m['acc'];
        if (t is! List || lat is! List || lng is! List ||
            t.length != lat.length || lat.length != lng.length) {
          return const HcRouteNoData();
        }
        final points = <HcRoutePoint>[];
        for (var i = 0; i < t.length; i++) {
          final a = acc is List && i < acc.length ? acc[i] : null;
          final accM = a is num && a.isFinite ? a.toDouble() : null;
          points.add(HcRoutePoint((t[i] as num).toInt(),
              (lat[i] as num).toDouble(), (lng[i] as num).toDouble(), accM));
        }
        return HcRouteData(points);
      case 'consent_required':
        return const HcRouteConsentRequired();
      case 'denied':
        return const HcRouteDenied();
      case 'unsupported':
        return const HcRouteUnsupported();
      default:
        return const HcRouteNoData();
    }
  }

  @override
  Future<HcRouteResult> readRoute(String id) async =>
      _route(await _invoke<Map<Object?, Object?>>('readRoute', {'id': id}));

  @override
  Future<HcRouteResult> requestRouteConsent(String id) async => _route(
      await _invoke<Map<Object?, Object?>>('requestRouteConsent', {'id': id}));

  @override
  Future<bool> openSettings() async {
    try {
      return await _invoke<bool>('openHealthConnectSettings') ?? false;
    } on HealthConnectException {
      return false;
    }
  }

  @override
  Future<bool> openInstall() async {
    try {
      return await _invoke<bool>('openHealthConnectInstall') ?? false;
    } on HealthConnectException {
      return false;
    }
  }

  @override
  Future<void> revokeAll() async {
    try {
      await _invoke<void>('revokeAllPermissions');
    } on HealthConnectException {
      // Best effort: the user can always revoke in Health Connect itself.
    }
  }
}
