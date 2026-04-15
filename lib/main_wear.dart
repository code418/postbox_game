import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:postbox_game/authentication_bloc/bloc.dart';
import 'package:postbox_game/user_repository.dart';
import 'package:postbox_game/wear/wear_app.dart';
import 'firebase_options.dart';

/// Wear OS entry point.
///
/// Shares Firebase config and business logic (auth, Cloud Functions, analytics)
/// with the phone app but launches a wearable-specific widget tree.
///
/// Build: flutter run --flavor wear -t lib/main_wear.dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await FirebaseAppCheck.instance.activate(
    // Wear OS is Android-only — no web or Apple providers needed.
    providerAndroid: kDebugMode
        ? const AndroidDebugProvider()
        : const AndroidPlayIntegrityProvider(),
  );
  runApp(const WearPostboxGame());
}
