import 'dart:async';

import 'package:postbox_game/firebase_functions_eu.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:postbox_game/maintenance_guard.dart';

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

    try {
      final settings = await messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        // Reset guard so re-initialisation is attempted on next sign-in cycle,
        // in case the user grants permission later via system settings.
        _initialized = false;
        return;
      }

      // Deliberately do NOT opt in to FCM's iOS foreground presentation here.
      // FCM would then show a native banner *and* deliver the message to
      // onMessage, where we already render a flutter_local_notifications
      // banner — the user would see two stacked notifications for every
      // event. By leaving FCM's foreground options at their default
      // (alert: false), the native banner is suppressed and the local
      // notification is the single source of truth on both iOS and Android.

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
      await _localNotifications.initialize(settings: initSettings);

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
          id: notification.hashCode,
          title: notification.title,
          body: notification.body,
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              _channelId,
              _channelName,
              importance: Importance.defaultImportance,
            ),
            iOS: DarwinNotificationDetails(),
          ),
        );
      });
    } catch (_) {
      // Reset guard so init() retries on the next sign-in cycle (e.g. if the
      // initial token fetch failed due to no network connectivity).
      // Cancel any subscriptions that were set up before the throw so the
      // retry does not leave duplicate FCM listeners attached.
      await _tokenRefreshSub?.cancel();
      await _onMessageSub?.cancel();
      _tokenRefreshSub = null;
      _onMessageSub = null;
      _initialized = false;
    }
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
    // Skip silently when the app is in read-only (maintenance) mode. Recovery
    // then happens on the next FCM onTokenRefresh or the next sign-in cycle
    // (which re-runs init) — NOT on mere foregrounding, which only refreshes
    // the home widget (see didChangeAppLifecycleState in main.dart). A token
    // fetched-but-not-registered during a maintenance window is therefore
    // undeliverable until one of those fires; acceptable because social
    // notifications are non-critical and the maintenance window is rare.
    if (MaintenanceGuard.isOn) return;
    try {
      await appFunctions
          .httpsCallable('registerFcmToken')
          .call<void>({'token': token});
    } catch (_) {
      // Token registration is non-critical — silently discard failures.
    }
  }
}
