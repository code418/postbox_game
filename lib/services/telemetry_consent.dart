import 'package:flutter/foundation.dart';

import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/consent_preferences.dart';
import 'package:postbox_game/services/crashlytics_helper.dart';
import 'package:postbox_game/services/perf_service.dart';

/// Apply the stored telemetry consent to every collection SDK. Called once at
/// cold start from `main()` (replacing the old unconditional `!kDebugMode`
/// calls) and again by whichever surface records a new choice.
///
/// Analytics runs on the stored toggle alone — ON by default, opt-out model
/// (and no debug gate, matching its previous behaviour of having none). Crash
/// reporting and performance monitoring are likewise legitimate-interest with
/// Settings opt-outs, and stay suppressed in debug builds as before. [isDebug]
/// is a test seam.
///
/// [includePerf] is false on Wear OS. Performance Monitoring auto-instruments
/// HTTP calls app-wide, but the watch makes few of them and has no surface on
/// which to present a third toggle — so rather than collect something the user
/// cannot object to, the watch forces perf collection OFF and offers opt-outs
/// for the two streams it does use (analytics and crash reporting).
Future<void> applyStoredTelemetryPreferences({
  bool isDebug = kDebugMode,
  bool includePerf = true,
}) async {
  final granted = await ConsentPreferences.analyticsGranted();
  final crash = await ConsentPreferences.crashReportingEnabled();

  await Analytics.setCollectionEnabled(granted);
  await CrashlyticsHelper.setCollectionEnabled(!isDebug && crash);

  if (!includePerf) {
    await PerfService.setCollectionEnabled(false);
    return;
  }
  final perf = await ConsentPreferences.perfMonitoringEnabled();
  await PerfService.setCollectionEnabled(!isDebug && perf);
}
