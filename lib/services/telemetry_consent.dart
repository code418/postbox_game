import 'package:flutter/foundation.dart';

import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/consent_preferences.dart';
import 'package:postbox_game/services/crashlytics_helper.dart';
import 'package:postbox_game/services/perf_service.dart';

/// Apply the stored telemetry consent to every collection SDK. Called once at
/// cold start from `main()` (replacing the old unconditional `!kDebugMode`
/// calls) and again by whichever surface records a new choice.
///
/// Analytics is consent-gated (decided AND granted — no debug gate, matching
/// its previous behaviour of having none). Crash reporting and performance
/// monitoring are legitimate-interest with a Settings opt-out, and stay
/// suppressed in debug builds as before. [isDebug] is a test seam.
Future<void> applyStoredTelemetryPreferences({bool isDebug = kDebugMode}) async {
  final decided = await ConsentPreferences.hasDecidedAnalytics();
  final granted = await ConsentPreferences.analyticsGranted();
  final crash = await ConsentPreferences.crashReportingEnabled();
  final perf = await ConsentPreferences.perfMonitoringEnabled();

  await Analytics.setCollectionEnabled(decided && granted);
  await CrashlyticsHelper.setCollectionEnabled(!isDebug && crash);
  await PerfService.setCollectionEnabled(!isDebug && perf);
}
