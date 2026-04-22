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
  return Geolocator.getCurrentPosition(
    desiredAccuracy: LocationAccuracy.high,
    forceAndroidLocationManager:
        forceLocationManager && !kIsWeb && Platform.isAndroid,
    timeLimit: const Duration(seconds: 30),
  );
}
