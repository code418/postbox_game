import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Handles FCM initialisation, permission requests, device token registration,
/// and foreground notification display via flutter_local_notifications.
class NotificationService {
  static final _localNotifications = FlutterLocalNotificationsPlugin();
  static const _channelId = 'postbox_social';
  static const _channelName = 'Social Notifications';

  /// Initialise FCM and register the device token with the backend.
  /// Safe to call multiple times — FirebaseMessaging deduplicates the
  /// onTokenRefresh listener internally.
  static Future<void> init() async {
    final messaging = FirebaseMessaging.instance;

    final settings = await messaging.requestPermission();
    if (settings.authorizationStatus == AuthorizationStatus.denied) return;

    final token = await messaging.getToken();
    if (token != null) {
      await _registerToken(token);
    }

    messaging.onTokenRefresh.listen(_registerToken);

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

    FirebaseMessaging.onMessage.listen((message) {
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
