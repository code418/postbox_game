// Shared fakes for the workout-claim (Health Connect) tests.

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/services/health_connect_bridge.dart';

class FakeCallableResult<T> implements HttpsCallableResult<T> {
  FakeCallableResult(this.data);
  @override
  final T data;
}

/// FirebaseFunctionsException's constructor is @protected; a subclass may
/// call it via super.
class FakeFunctionsException extends FirebaseFunctionsException {
  FakeFunctionsException(String code, {super.message = 'x', super.details}) : super(code: code);
}

/// Remote Config with the workout flags controllable; everything else at the
/// in-app defaults.
class FakeActivityRemoteConfig extends Fake implements FirebaseRemoteConfig {
  FakeActivityRemoteConfig({this.enabled = true, this.killed = false, this.maintenance = false});
  bool enabled;
  bool killed;
  bool maintenance;

  @override
  bool getBool(String key) => switch (key) {
        RemoteConfigService.keyActivityClaimsEnabled => enabled,
        RemoteConfigService.keyKillSwitchActivityClaims => killed,
        RemoteConfigService.keyMaintenanceMode => maintenance,
        _ => false,
      };

  @override
  int getInt(String key) => key == RemoteConfigService.keyActivityClaimGraceHours
      ? RemoteConfigService.defaultActivityClaimGraceHours
      : 0;

  @override
  String getString(String key) => key == RemoteConfigService.keyActivityOriginAllowlist
      ? RemoteConfigService.defaultActivityOriginAllowlistJson
      : '';

  @override
  double getDouble(String key) => 0.0;
}

/// Scriptable Health Connect bridge that records what was asked of it.
class FakeHealthConnectBridge implements HealthConnectBridge {
  bool supported = true;
  HcAvailability avail = HcAvailability.available;
  Set<String> granted = {
    HealthConnectPermissions.readExercise,
    HealthConnectPermissions.readExerciseRoutes,
  };
  Set<String> grantOnRequest = {
    HealthConnectPermissions.readExercise,
    HealthConnectPermissions.readExerciseRoutes,
  };
  List<HcSession> sessions = [];
  final Map<String, HcRouteResult> routes = {};
  final Map<String, HcRouteResult> consentRoutes = {};

  int readSessionsCalls = 0;
  int readRouteCalls = 0;
  final List<String> consentRequests = [];
  int permissionRequests = 0;
  bool revoked = false;

  @override
  bool get isSupportedPlatform => supported;

  @override
  Future<HcAvailability> availability() async => supported ? avail : HcAvailability.unsupported;

  @override
  Future<Set<String>> grantedPermissions() async => granted;

  @override
  Future<Set<String>> requestPermissions() async {
    permissionRequests++;
    granted = {...grantOnRequest};
    return granted;
  }

  @override
  Future<List<HcSession>> readSessions({required int sinceMs, required int untilMs}) async {
    readSessionsCalls++;
    return sessions;
  }

  @override
  Future<HcRouteResult> readRoute(String id) async {
    readRouteCalls++;
    return routes[id] ?? const HcRouteNoData();
  }

  @override
  Future<HcRouteResult> requestRouteConsent(String id) async {
    consentRequests.add(id);
    return consentRoutes[id] ?? const HcRouteDenied();
  }

  @override
  Future<bool> openSettings() async => true;

  @override
  Future<bool> openInstall() async => true;

  @override
  Future<void> revokeAll() async => revoked = true;
}

/// A straight eastward GPS track (1 point / 10 s, 10 m apart).
List<HcRoutePoint> eastTrack(int startMs, {int points = 30}) => [
      for (var i = 0; i < points; i++) HcRoutePoint(startMs + i * 10000, 51.5, -0.12 + i * 0.000144),
    ];

/// One matchActivityRoute candidate DTO.
Map<String, Object> candidateDto(String key, int passedAtMs, {String monarch = 'VR', int points = 7}) => {
      'token': 'token-$key',
      'key': key,
      'passedAtMs': passedAtMs,
      'claimDate': '2026-11-02',
      'boxes': [
        {'monarch': monarch, 'points': points}
      ],
    };
