import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/consent_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('ConsentPreferences defaults', () {
    test('analytics is undecided and not granted (opt-in)', () async {
      expect(await ConsentPreferences.hasDecidedAnalytics(), isFalse);
      expect(await ConsentPreferences.analyticsGranted(), isFalse);
    });

    test('crash reporting and perf monitoring default on (legitimate interest)',
        () async {
      expect(await ConsentPreferences.crashReportingEnabled(), isTrue);
      expect(await ConsentPreferences.perfMonitoringEnabled(), isTrue);
    });
  });

  group('ConsentPreferences round trips', () {
    test('setAnalyticsConsent(true) records decided + granted', () async {
      await ConsentPreferences.setAnalyticsConsent(true);
      expect(await ConsentPreferences.hasDecidedAnalytics(), isTrue);
      expect(await ConsentPreferences.analyticsGranted(), isTrue);
    });

    test('setAnalyticsConsent(false) records decided but not granted',
        () async {
      await ConsentPreferences.setAnalyticsConsent(false);
      expect(await ConsentPreferences.hasDecidedAnalytics(), isTrue);
      expect(await ConsentPreferences.analyticsGranted(), isFalse);
    });

    test('crash and perf toggles round-trip', () async {
      await ConsentPreferences.setCrashReportingEnabled(false);
      await ConsentPreferences.setPerfMonitoringEnabled(false);
      expect(await ConsentPreferences.crashReportingEnabled(), isFalse);
      expect(await ConsentPreferences.perfMonitoringEnabled(), isFalse);
      await ConsentPreferences.setCrashReportingEnabled(true);
      expect(await ConsentPreferences.crashReportingEnabled(), isTrue);
    });
  });
}
