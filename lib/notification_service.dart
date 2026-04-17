import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Handles FCM initialisation, permission requests, device token registration,
/// and foreground notification display via flutter_local_notifications.
class NotificationService {
  static final _localNotifications = FlutterLocalNotificationsPlugin();
  static const _channelId = 'postbox_social';
  static const _channelName = 'Social Notifications';
  static bool _initialized = false;
  static StreamSubscription<String>? _tokenRefreshSub;
  static StreamSubscription<dynamic>? _onMessageSub;

  /// Initialise FCM and register the device token with the backend.
  /// Safe to call multiple times — subscriptions are cancelled on [reset]
  /// before re-registering to avoid duplicate listeners.
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    final messaging = FirebaseMessaging.instance;

    final settings = await messaging.requestPermission();
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      // Reset guard so re-initialisation is attempted on next sign-in cycle,
      // in case the user grants permission later via system settings.
      _initialized = false;
      return;
    }

    final token = await messaging.getToken();
    if (token != null) {
      await _registerToken(token);
    }

    _tokenRefreshSub = messaging.onTokenRefresh.listen(_registerToken);

    // Configure flutter_local_notifications so FCM messages display when the
    // app is in the foreground (FCM does not auto-show system notifications
    // in the foreground on Android or iOS).
    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    );
    await _localNotifications.initialize(initSettings);

    await _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            importance: Importance.defaultImportance,
          ),
        );

    _onMessageSub = FirebaseMessaging.onMessage.listen((message) {
      final notification = message.notification;
      if (notification == null) return;
      _localNotifications.show(
        notification.hashCode,
        notification.title,
        notification.body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            importance: Importance.defaultImportance,
          ),
        ),
      );
    });
  }

  /// Resets the initialisation guard so [init] re-registers on the next sign-in.
  /// Cancels active FCM listeners to prevent duplicates across sign-in cycles.
  /// Deletes the FCM token so it is no longer deliverable to the signed-out
  /// user's account — FCM will return not-registered on the next delivery
  /// attempt, triggering stale-token pruning on the backend.
  /// Call this when the user signs out.
  static Future<void> reset() async {
    await _tokenRefreshSub?.cancel();
    await _onMessageSub?.cancel();
    _tokenRefreshSub = null;
    _onMessageSub = null;
    _initialized = false;
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {
      // Token deletion is best-effort; failure does not block sign-out.
    }
  }

  static Future<void> _registerToken(String token) async {
    try {
      await FirebaseFunctions.instance
          .httpsCallable('registerFcmToken')
          .call<void>({'token': token});
    } catch (_) {
      // Token registration is non-critical — silently discard failures.
    }
  }
}
