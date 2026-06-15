import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

/// Thin wrapper around Firebase Crashlytics for structured context (custom
/// keys) and non-fatal (handled) error reporting.
///
/// Same static-wrapper + `@visibleForTesting` instance-seam pattern as
/// `Analytics` / `RemoteConfigService` / `PerfService`. Every SDK call is
/// guarded so logging can never throw into the code path it observes.
///
/// Privacy: never pass emails, display names, or exact coordinates as keys or
/// values — only coarse/categorical context (auth provider, active tab, claim
/// id, monarch code, permission flag, last config fetch time).
class CrashlyticsHelper {
  CrashlyticsHelper._();

  static FirebaseCrashlytics? _crashlytics;

  /// Lazily resolves the real SDK on first production use; tests inject a fake
  /// via [instance] before any call site reads it (so the real singleton is
  /// never touched headless).
  static FirebaseCrashlytics get _fc =>
      _crashlytics ??= FirebaseCrashlytics.instance;

  @visibleForTesting
  static set instance(FirebaseCrashlytics value) => _crashlytics = value;

  @visibleForTesting
  static FirebaseCrashlytics get instance => _fc;

  @visibleForTesting
  static void resetForTest() {
    _crashlytics = null;
    _seenDedupeKeys.clear();
  }

  // ── Custom-key names ───────────────────────────────────────────────────────
  static const String keyAuthState = 'auth_state';
  static const String keyActiveTab = 'active_tab';
  static const String keyLastClaimId = 'last_claim_id';
  static const String keyLastMonarch = 'last_monarch';
  static const String keyRemoteConfigFetchTs = 'remote_config_fetch_ts';
  static const String keyHasLocationPermission = 'has_location_permission';

  /// Crashlytics truncates custom-key values at 1024 chars; guard so we never
  /// send something pathological.
  static const int _maxValueLength = 1024;

  /// Dedupe keys already recorded this process session (for noisy, expected
  /// network flakes — record once, then drop).
  static final Set<String> _seenDedupeKeys = <String>{};

  /// Set a structured context key. Length-guarded; swallows SDK errors.
  static Future<void> setContext(String key, Object? value) async {
    try {
      final v = value?.toString() ?? '';
      await _fc.setCustomKey(
        key,
        v.length > _maxValueLength ? v.substring(0, _maxValueLength) : v,
      );
    } catch (e) {
      debugPrint('CrashlyticsHelper.setContext($key) failed: $e');
    }
  }

  /// Record a handled (non-fatal) error. Always `fatal: false`.
  ///
  /// Pass [dedupeKey] for expected, repeating flakes (e.g. offline callable
  /// failures): the first occurrence per session is recorded, later ones drop.
  static Future<void> recordHandled(
    Object error,
    StackTrace? stack, {
    String? reason,
    String? dedupeKey,
  }) async {
    if (dedupeKey != null && !_seenDedupeKeys.add(dedupeKey)) return;
    try {
      await _fc.recordError(
        error,
        stack,
        reason: reason,
        fatal: false,
      );
    } catch (e) {
      debugPrint('CrashlyticsHelper.recordHandled failed: $e');
    }
  }

  /// Toggle collection. Called once from `main()` with `!kDebugMode` so debug
  /// runs don't upload crash reports.
  static Future<void> setCollectionEnabled(bool enabled) async {
    try {
      await _fc.setCrashlyticsCollectionEnabled(enabled);
    } catch (e) {
      debugPrint('CrashlyticsHelper.setCollectionEnabled failed: $e');
    }
  }
}
