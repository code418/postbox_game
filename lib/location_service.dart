import 'dart:async' show TimeoutException;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:postbox_game/services/crashlytics_helper.dart';

/// The category of a [LocationServiceException].
///
/// Callers should branch on this enum, not on the human-readable message —
/// formerly callers ran `e.toString().contains('permanently denied')` in four
/// files, which silently broke whenever the message text was tweaked.
enum LocationErrorKind {
  /// `Location services` is the OS-level toggle (e.g. "Location" off in
  /// Settings). Recover via `Geolocator.openLocationSettings()`.
  servicesDisabled,

  /// The user dismissed the runtime permission prompt this session. Asking
  /// again may succeed.
  permissionDenied,

  /// The user picked "Never" / "Don't ask again" — Android won't re-prompt.
  /// Recover via `Geolocator.openAppSettings()`.
  permissionPermanentlyDenied,
}

/// Typed exception thrown by [getPosition] so callers can dispatch on
/// [kind] instead of pattern-matching on the human-readable message.
///
/// The [message] is preserved for SnackBar/log surfaces.
class LocationServiceException implements Exception {
  const LocationServiceException(this.kind, this.message);

  final LocationErrorKind kind;
  final String message;

  @override
  String toString() => 'LocationServiceException(${kind.name}): $message';
}

/// Returns the device's current high-accuracy position after checking and, if
/// necessary, requesting location permission.
///
/// Throws a [LocationServiceException] when:
/// - location services are disabled ([LocationErrorKind.servicesDisabled])
/// - permission is denied this session ([LocationErrorKind.permissionDenied])
/// - permission is permanently denied
///   ([LocationErrorKind.permissionPermanentlyDenied])
///
/// Pass [forceLocationManager] to bypass Play Services fused location and
/// use Android's core `LocationManager` instead. Needed on Wear OS (especially
/// emulator images) where fused is not implemented and crashes the plugin.
Future<Position> getPosition({bool forceLocationManager = false}) async {
  // Fused location's isLocationServiceEnabled crashes on Wear emulator images
  // (ApiException: 10). Skip the pre-check when forcing LocationManager —
  // getCurrentPosition will surface a disabled-services error if it applies.
  if (!forceLocationManager) {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw const LocationServiceException(
        LocationErrorKind.servicesDisabled,
        'Location services are disabled.',
      );
    }
  }
  LocationPermission permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied) {
      CrashlyticsHelper.setContext(
          CrashlyticsHelper.keyHasLocationPermission, false);
      throw const LocationServiceException(
        LocationErrorKind.permissionDenied,
        'Location permission denied.',
      );
    }
  }
  if (permission == LocationPermission.deniedForever) {
    CrashlyticsHelper.setContext(
        CrashlyticsHelper.keyHasLocationPermission, false);
    throw const LocationServiceException(
      LocationErrorKind.permissionPermanentlyDenied,
      'Location permission permanently denied. Enable it in Settings.',
    );
  }
  CrashlyticsHelper.setContext(
      CrashlyticsHelper.keyHasLocationPermission, true);
  final useAndroidManager =
      forceLocationManager && !kIsWeb && Platform.isAndroid;
  final LocationSettings settings = useAndroidManager
      ? AndroidSettings(
          accuracy: LocationAccuracy.high,
          forceLocationManager: true,
          timeLimit: const Duration(seconds: 30),
        )
      : const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 30),
        );
  try {
    return await Geolocator.getCurrentPosition(locationSettings: settings);
  } on TimeoutException {
    // v1.5 offline play: a stale fix beats no fix. Under tree cover or
    // indoors-by-the-window the 30 s fresh fix can time out while the OS
    // still holds a recent one; the claim radius is enforced server-side, so
    // a slightly-stale position degrades accuracy, never integrity.
    final last = await Geolocator.getLastKnownPosition();
    if (last != null) return last;
    rethrow;
  }
}

/// Returns a continuous stream of GPS positions for live tracking.
///
/// Callers must have already acquired location permission (e.g. via
/// [getPosition]) before subscribing. The stream surfaces platform errors
/// (permission denied, services off) directly as stream errors — it does
/// **not** request permissions itself.
///
/// [accuracy] defaults to [LocationAccuracy.bestForNavigation] for the
/// turn-by-turn fidelity needed by the live-route screen.
/// [distanceFilterMetres] suppresses updates smaller than this distance
/// (default 5 m) to avoid flooding the UI.
///
/// Pass [forceLocationManager] to bypass Play Services fused location and use
/// Android's core `LocationManager` instead — required on Wear OS where the
/// fused provider is not available.
Stream<Position> positionStream({
  LocationAccuracy accuracy = LocationAccuracy.bestForNavigation,
  int distanceFilterMetres = 5,
  bool forceLocationManager = false,
}) {
  final useAndroidManager =
      forceLocationManager && !kIsWeb && Platform.isAndroid;
  final LocationSettings settings = useAndroidManager
      ? AndroidSettings(
          accuracy: accuracy,
          distanceFilter: distanceFilterMetres,
          forceLocationManager: true,
        )
      : LocationSettings(
          accuracy: accuracy,
          distanceFilter: distanceFilterMetres,
        );
  return Geolocator.getPositionStream(locationSettings: settings);
}
