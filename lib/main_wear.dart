import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/services/crashlytics_helper.dart';
import 'package:postbox_game/services/telemetry_consent.dart';
import 'package:postbox_game/wear/wear_app.dart';
import 'firebase_options.dart';
import 'oauth_client_ids.dart';

/// Wear OS entry point.
///
/// Shares Firebase config and business logic (auth, Cloud Functions, analytics)
/// with the phone app but launches a wearable-specific widget tree.
///
/// Build: flutter run --flavor wear -t lib/main_wear.dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // On Android the native FirebaseInitProvider auto-initializes the [DEFAULT]
  // app from google-services.json before main() runs. In release/AOT builds it
  // wins the race, so calling initializeApp() again throws [core/duplicate-app]
  // — which, thrown here before runApp(), leaves a blank screen that Google
  // Play flags as a crash-on-launch. Guard so initialization is idempotent.
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }
  // Route uncaught framework + platform errors to Crashlytics, same as the
  // phone. Without this the watch reported no Dart errors at all: a crash on
  // the wrist was invisible except through store reviews.
  FlutterError.onError = CrashlyticsHelper.reportFlutterError;
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };
  // Apply the stored GDPR telemetry consent. The watch keeps its own
  // SharedPreferences copy of the choice (consent is per-device SDK state) and
  // exposes the opt-outs on its Privacy page. Until this ran, the manifest's
  // `firebase_analytics_collection_enabled=false` left every Analytics.* call
  // on the watch a silent no-op. Perf Monitoring stays off on the watch — see
  // [applyStoredTelemetryPreferences].
  unawaited(applyStoredTelemetryPreferences(includePerf: false));
  unawaited(
      CrashlyticsHelper.setContext(CrashlyticsHelper.keySurface, 'wear'));
  await FirebaseAppCheck.instance.activate(
    // Wear OS is Android-only — no web or Apple providers needed.
    providerAndroid: kDebugMode
        ? const AndroidDebugProvider()
        : const AndroidPlayIntegrityProvider(),
  );
  // google_sign_in 7.x requires initialize() before authenticate().
  // serverClientId is the Firebase Auth web OAuth client (type 3 in
  // google-services.json) — needed on Android to issue an ID token.
  // Sourced from lib/oauth_client_ids.dart so it can't drift from main.dart.
  await GoogleSignIn.instance.initialize(
    serverClientId: webClientId,
  );
  // Remote Config, same as main.dart. Without this the watch never loaded the
  // defaults OR fetched, so every flag read its type-default: the RC-driven
  // claim radius silently fell back to the hard-coded 30 m, and — because
  // MaintenanceGuard is a pure Remote Config read and `startScoring` has no
  // server-side maintenance check — maintenance mode could not stop a watch
  // from claiming into a mid-migration database. Fire-and-forget: defaults
  // serve immediately and remote values activate when the fetch resolves.
  unawaited(RemoteConfigService.instance.init());
  runApp(const WearPostboxGame());
}
