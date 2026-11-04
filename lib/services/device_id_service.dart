import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A stable, privacy-preserving per-install identifier for the shadow-mode
/// repeated-device abuse signal (one install claiming across many accounts —
/// see functions/src/abuse.ts / _abuseSignals.repeatedDeviceSignal).
///
/// Deliberately NOT derived from hardware: a random 256-bit value generated
/// once and persisted in SharedPreferences. It is app-global, so it survives
/// account switches (multi-accounting on one install shares it) and resets only
/// when the user clears app data — the same reset semantics as a Firebase
/// installation id, without adding a native Firebase plugin (which would risk
/// the firebase_core version ceiling). Sent to startScoring as `deviceIdHash`;
/// being random, it already reveals nothing about the device.
class DeviceIdService {
  DeviceIdService._();

  static const String _key = 'device_install_id';
  static String? _cached;

  /// The persisted install id, generating + storing one on first use. The id is
  /// 64 lowercase-hex chars (matches the server's deviceIdHash length bound).
  ///
  /// Best-effort: returns null if SharedPreferences is unavailable so the claim
  /// path never breaks — the abuse signal is optional and fails open.
  static Future<String?> get() async {
    if (_cached != null) return _cached;
    try {
      final prefs = await SharedPreferences.getInstance();
      var id = prefs.getString(_key);
      if (id == null || id.length != 64) {
        id = _generate();
        await prefs.setString(_key, id);
      }
      _cached = id;
      return id;
    } catch (_) {
      return null;
    }
  }

  static String _generate() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  @visibleForTesting
  static void resetForTest() => _cached = null;
}
