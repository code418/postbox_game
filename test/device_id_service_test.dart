import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:postbox_game/services/device_id_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DeviceIdService.resetForTest();
  });

  test('generates a 64-char lowercase-hex id on first use', () async {
    final id = await DeviceIdService.get();
    expect(id, isNotNull);
    expect(id!.length, equals(64));
    expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(id), isTrue);
  });

  test('returns the same id across calls (persisted)', () async {
    final a = await DeviceIdService.get();
    DeviceIdService.resetForTest(); // drop the in-memory cache; prefs keeps it
    final b = await DeviceIdService.get();
    expect(a, equals(b));
  });

  test('reuses an already-stored id', () async {
    final existing = 'a' * 64;
    SharedPreferences.setMockInitialValues({'device_install_id': existing});
    DeviceIdService.resetForTest();
    expect(await DeviceIdService.get(), equals(existing));
  });
}
