import 'dart:async';

import 'package:firebase_performance/firebase_performance.dart';
import 'package:flutter/foundation.dart';

/// Thin wrapper around Firebase Performance **custom code traces**.
///
/// Mirrors the static-wrapper + `@visibleForTesting` instance-seam pattern used
/// by `Analytics` and `RemoteConfigService`: tests inject a fake
/// [FirebasePerformance] via [instance] before any call site reads it.
///
/// We deliberately ship without the `com.google.firebase.firebase-perf` Gradle
/// plugin (AGP-8.x-incompatible). That plugin only adds *automatic* network /
/// screen-render traces; the custom code traces below work through the Flutter
/// plugin alone. See `pubspec.yaml` / `android/app/build.gradle`.
///
/// Every Performance-SDK call is wrapped so instrumentation can never throw into
/// the feature it measures — a failed trace just produces no data.
class PerfService {
  PerfService._();

  static FirebasePerformance? _perf;

  /// Lazily resolves the real SDK on first production use; tests inject a fake
  /// via [instance] before any call site reads it (so the real singleton is
  /// never touched headless).
  static FirebasePerformance get _fp => _perf ??= FirebasePerformance.instance;

  @visibleForTesting
  static set instance(FirebasePerformance perf) => _perf = perf;

  @visibleForTesting
  static FirebasePerformance get instance => _fp;

  @visibleForTesting
  static void resetForTest() => _perf = null;

  /// Toggle collection. Called once from `main()` with `!kDebugMode` so debug
  /// runs stay out of the dashboard.
  static Future<void> setCollectionEnabled(bool enabled) async {
    try {
      await _fp.setPerformanceCollectionEnabled(enabled);
    } catch (e) {
      debugPrint('PerfService.setCollectionEnabled failed: $e');
    }
  }

  /// Wrap [body] in a custom trace named [name]. The [TraceHandle] handed to
  /// [body] lets the call site attach attributes/metrics whose values are only
  /// known after the work runs (e.g. a result count). The trace is always
  /// stopped, even if [body] throws.
  static Future<T> traceAsync<T>(
    String name,
    Future<T> Function(TraceHandle trace) body, {
    Map<String, String>? attributes,
  }) async {
    final handle = await start(name, attributes: attributes);
    try {
      return await body(handle);
    } finally {
      await handle.stop();
    }
  }

  /// Start a trace and return a handle the caller stops manually — for spans
  /// that don't fit a single async body (an onboarding flow, a tile fetch).
  /// Always resolves to a non-null handle; a failed start yields a silent no-op.
  static Future<TraceHandle> start(
    String name, {
    Map<String, String>? attributes,
  }) async {
    try {
      final trace = _fp.newTrace(name);
      await trace.start();
      attributes?.forEach(trace.putAttribute);
      return TraceHandle._(trace);
    } catch (e, st) {
      debugPrint('PerfService.start($name) failed: $e\n$st');
      return TraceHandle._(null);
    }
  }
}

/// Caller-facing handle over a started [Trace]. Swallows SDK errors and is safe
/// to [stop] more than once. Wraps a nullable trace so the no-op (failed-start)
/// path needs no null-checks at call sites.
class TraceHandle {
  TraceHandle._(this._trace);

  final Trace? _trace;
  bool _stopped = false;

  /// String attribute (categorical, e.g. period/variant/outcome). Firebase caps
  /// at 5 attributes per trace, names ≤ 40 chars, values ≤ 100 chars.
  void putAttribute(String name, String value) {
    try {
      _trace?.putAttribute(name, value);
    } catch (_) {/* never break the wrapped feature */}
  }

  /// Integer metric (counts, e.g. resultsCount/rowCount).
  void setMetric(String name, int value) {
    try {
      _trace?.setMetric(name, value);
    } catch (_) {/* never break the wrapped feature */}
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    try {
      await _trace?.stop();
    } catch (e) {
      debugPrint('TraceHandle.stop failed: $e');
    }
  }
}

/// Trace + attribute/metric key names in one place to prevent typo
/// fragmentation across call sites. Keep the trace count well under the
/// 100-name free-tier cap.
class PerfTraces {
  PerfTraces._();

  // Trace names.
  static const String callableNearbyPostboxes = 'callable.nearbyPostboxes';
  static const String callableStartScoring = 'callable.startScoring';
  static const String mapTileLoad = 'map.tileLoad';
  static const String friendsLoad = 'friends.load';
  static const String leaderboardRender = 'leaderboard.render';
  static const String introOnboarding = 'intro.onboarding';

  // Attribute keys (string).
  static const String attrRadius = 'radius';
  static const String attrMonarch = 'monarch';
  static const String attrOutcome = 'outcome';
  static const String attrZoom = 'zoom';
  static const String attrPeriod = 'period';
  static const String attrVariant = 'variant';

  // Metric keys (int).
  static const String metricResultsCount = 'resultsCount';
  static const String metricCount = 'count';
  static const String metricRowCount = 'rowCount';
}
