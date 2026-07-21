import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_performance/firebase_performance.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/consent_preferences.dart';
import 'package:postbox_game/services/crashlytics_helper.dart';
import 'package:postbox_game/services/perf_service.dart';
import 'package:postbox_game/services/telemetry_consent.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAnalytics extends Fake implements FirebaseAnalytics {
  bool? collectionEnabled;
  @override
  Future<void> setAnalyticsCollectionEnabled(bool enabled) async {
    collectionEnabled = enabled;
  }
}

class _FakeCrashlytics extends Fake implements FirebaseCrashlytics {
  bool? collectionEnabled;
  @override
  Future<void> setCrashlyticsCollectionEnabled(bool enabled) async {
    collectionEnabled = enabled;
  }
}

class _FakePerformance extends Fake implements FirebasePerformance {
  bool? collectionEnabled;
  @override
  Future<void> setPerformanceCollectionEnabled(bool enabled) async {
    collectionEnabled = enabled;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAnalytics fakeAnalytics;
  late _FakeCrashlytics fakeCrashlytics;
  late _FakePerformance fakePerf;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    fakeAnalytics = _FakeAnalytics();
    fakeCrashlytics = _FakeCrashlytics();
    fakePerf = _FakePerformance();
    Analytics.instance = fakeAnalytics;
    CrashlyticsHelper.resetForTest();
    CrashlyticsHelper.instance = fakeCrashlytics;
    PerfService.resetForTest();
    PerfService.instance = fakePerf;
  });

  test('defaults (release): analytics, crash, and perf all on', () async {
    await applyStoredTelemetryPreferences(isDebug: false);
    expect(fakeAnalytics.collectionEnabled, isTrue);
    expect(fakeCrashlytics.collectionEnabled, isTrue);
    expect(fakePerf.collectionEnabled, isTrue);
  });

  test('an explicit opt-in keeps collection on', () async {
    await ConsentPreferences.setAnalyticsConsent(true);
    await applyStoredTelemetryPreferences(isDebug: false);
    expect(fakeAnalytics.collectionEnabled, isTrue);
  });

  test('an analytics opt-out turns collection off', () async {
    await ConsentPreferences.setAnalyticsConsent(false);
    await applyStoredTelemetryPreferences(isDebug: false);
    expect(fakeAnalytics.collectionEnabled, isFalse);
  });

  test('crash/perf opt-outs are honoured in release builds', () async {
    await ConsentPreferences.setCrashReportingEnabled(false);
    await ConsentPreferences.setPerfMonitoringEnabled(false);
    await applyStoredTelemetryPreferences(isDebug: false);
    expect(fakeCrashlytics.collectionEnabled, isFalse);
    expect(fakePerf.collectionEnabled, isFalse);
  });

  test('debug builds force crash+perf off, analytics still follows consent',
      () async {
    await ConsentPreferences.setAnalyticsConsent(true);
    await applyStoredTelemetryPreferences(isDebug: true);
    expect(fakeCrashlytics.collectionEnabled, isFalse);
    expect(fakePerf.collectionEnabled, isFalse);
    expect(fakeAnalytics.collectionEnabled, isTrue);
  });
}
