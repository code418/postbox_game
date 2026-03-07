import 'package:shared_preferences/shared_preferences.dart';

const String _keyDistanceUnit = 'distance_unit';

enum DistanceUnit { meters, miles }

extension DistanceUnitX on DistanceUnit {
  String get label => this == DistanceUnit.meters ? 'Meters' : 'Miles';
  String get short => this == DistanceUnit.meters ? 'm' : 'mi';
}

/// User preferences (distance display, etc.).
class AppPreferences {
  static Future<DistanceUnit> getDistanceUnit() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_keyDistanceUnit);
    if (v == 'miles') return DistanceUnit.miles;
    return DistanceUnit.meters;
  }

  static Future<void> setDistanceUnit(DistanceUnit unit) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDistanceUnit, unit == DistanceUnit.miles ? 'miles' : 'meters');
  }

  /// Converts meters to display value; callers use [AppPreferences.getDistanceUnit] for unit.
  static double metersToDisplay(double meters, DistanceUnit unit) {
    if (unit == DistanceUnit.miles) return meters * 0.000621371;
    return meters;
  }

  static String formatDistance(double meters, DistanceUnit unit) {
    final v = metersToDisplay(meters, unit);
    if (unit == DistanceUnit.miles) return '${v.toStringAsFixed(1)} mi';
    return '${v.toStringAsFixed(0)} m';
  }
}
