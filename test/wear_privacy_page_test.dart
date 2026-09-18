// The watch's telemetry opt-outs.
//
// Consent is device-local SharedPreferences state, so a choice made on the
// phone never reaches the watch. The privacy policy promises every stream can
// be switched off; before this page the watch collected with no way to object.
// These tests pin that the toggles both persist the choice AND re-apply it to
// the live SDKs, and that Performance Monitoring stays off on Wear.

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_performance/firebase_performance.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/consent_preferences.dart';
import 'package:postbox_game/services/crashlytics_helper.dart';
import 'package:postbox_game/services/perf_service.dart';
import 'package:postbox_game/wear/wear_privacy_page.dart';
import 'package:postbox_game/wear/wear_theme.dart';
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

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: WearTheme.dark,
      home: const WearPrivacyPage(),
    ));
    // One extra pump for the async SharedPreferences read.
    await tester.pumpAndSettle();
  }

  testWidgets('both toggles render, defaulting to on (opt-out model)',
      (tester) async {
    await pumpPage(tester);

    expect(find.text('Privacy'), findsOneWidget);
    expect(find.text('Analytics'), findsOneWidget);
    expect(find.text('Crash reports'), findsOneWidget);

    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches, hasLength(2));
    expect(switches.every((s) => s.value), isTrue);
  });

  testWidgets('turning analytics off persists AND applies immediately',
      (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();

    expect(await ConsentPreferences.analyticsGranted(), isFalse);
    expect(fakeAnalytics.collectionEnabled, isFalse);
  });

  testWidgets('turning crash reports off persists AND applies immediately',
      (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byType(Switch).last);
    await tester.pumpAndSettle();

    expect(await ConsentPreferences.crashReportingEnabled(), isFalse);
    expect(fakeCrashlytics.collectionEnabled, isFalse);
  });

  testWidgets('a stored opt-out is reflected when the page loads',
      (tester) async {
    await ConsentPreferences.setAnalyticsConsent(false);
    await pumpPage(tester);

    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches.first.value, isFalse);
    expect(switches.last.value, isTrue);
  });

  testWidgets('applying consent from the watch never enables Perf Monitoring',
      (tester) async {
    // The watch has no third toggle, so perf must stay off however the other
    // two are set — otherwise it would collect with no way to object.
    await ConsentPreferences.setPerfMonitoringEnabled(true);
    await pumpPage(tester);

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();

    expect(fakePerf.collectionEnabled, isFalse);
  });

  testWidgets('shows a spinner until the stored choice has been read',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: WearTheme.dark,
      home: const WearPrivacyPage(),
    ));
    // No settle: the SharedPreferences read is still in flight.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    await tester.pumpAndSettle();
  });
}
