import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Returns the device's current high-accuracy position after checking and, if
/// necessary, requesting location permission.
///
/// Throws an [Exception] with a human-readable message when:
/// - location services are disabled
/// - the user denies permission (temporarily or permanently)
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
      throw Exception('Location services are disabled.');
    }
  }
  LocationPermission permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied) {
      throw Exception('Location permission denied.');
    }
  }
  if (permission == LocationPermission.deniedForever) {
    throw Exception(
        'Location permission permanently denied. Enable it in Settings.');
  }
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
  return Geolocator.getCurrentPosition(locationSettings: settings);
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
