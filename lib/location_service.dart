import 'package:geolocator/geolocator.dart';

/// Returns the device's current high-accuracy position after checking and, if
/// necessary, requesting location permission.
///
/// Throws an [Exception] with a human-readable message when:
/// - location services are disabled
/// - the user denies permission (temporarily or permanently)
Future<Position> getPosition() async {
  final serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) {
    throw Exception('Location services are disabled.');
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
      desiredAccuracy: LocationAccuracy.high);
}
