import 'dart:async';

import 'package:postbox_game/firebase_functions_eu.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
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

  /// Whether [status] lets notifications through.
  static bool isGranted(AuthorizationStatus status) =>
      status == AuthorizationStatus.authorized ||
      status == AuthorizationStatus.provisional;

  /// Whether FCM rides on APNs here (the iOS and macOS apps, not the web).
  /// Decides how a message that arrives while the app is open is shown,
  /// and whether `getToken()` must wait for an APNs device token first.
  static bool usesApns({
    required bool isWeb,
    required TargetPlatform platform,
  }) =>
      !isWeb &&
      (platform == TargetPlatform.iOS || platform == TargetPlatform.macOS);

  /// The current notification permission, or null if it can't be read.
  static Future<AuthorizationStatus?> permissionStatus() async {
    try {
      final settings =
          await FirebaseMessaging.instance.getNotificationSettings();
      return settings.authorizationStatus;
    } catch (_) {
      return null;
    }
  }

  /// Initialise FCM and register the device token with the backend, if
  /// notification permission is ALREADY granted. Never prompts: the ask
  /// comes after the player's first claim ([requestAndInit], behind the
  /// guide's pre-prompt), because iOS allows one system prompt per install
  /// and spending it straight after sign-up, before the player has seen
  /// anything worth being notified about, wastes it.
  ///
  /// Called on sign-in, on resume (to pick up a grant made in system
  /// settings) and after Route Mode's own permission request. Safe to call
  /// multiple times: subscriptions are cancelled on [reset] before
  /// re-registering to avoid duplicate listeners.
  static Future<void> init() => _init(prompt: false);

  /// Shows the system permission prompt, then initialises as [init] does.
  static Future<void> requestAndInit() => _init(prompt: true);

  static Future<void> _init({required bool prompt}) async {
    if (_initialized) return;
    _initialized = true;

    final messaging = FirebaseMessaging.instance;

    try {
      final settings = prompt
          ? await messaging.requestPermission()
          : await messaging.getNotificationSettings();
      if (!isGranted(settings.authorizationStatus)) {
        // Reset guard so a later call (resume after a grant in system
        // settings, the post-claim prompt, the next sign-in) can retry.
        _initialized = false;
        return;
      }

      final apns =
          usesApns(isWeb: kIsWeb, platform: defaultTargetPlatform);
      if (apns) {
        // On iOS, firebase_messaging makes itself the UNUserNotificationCenter
        // delegate at launch, and its willPresent hook applies FCM's
        // foreground presentation options to EVERY notification, local ones
        // included. Left at the default (none), it hid both the FCM banner
        // and the flutter_local_notifications re-post below, so nothing
        // showed while the app was open. So iOS presents the FCM notification
        // natively and skips the re-post (one banner, as on Android).
        await messaging.setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );
        // getToken() throws apns-token-not-set until APNs registration
        // (started by the plugin at launch) has delivered a device token,
        // which can lag a cold-start sign-in.
        await _waitForApnsToken(messaging);
      }

      final token = await messaging.getToken();
      if (token != null) {
        await _registerToken(token);
      }

      _tokenRefreshSub = messaging.onTokenRefresh.listen(_registerToken);

      // Configure flutter_local_notifications so FCM messages display when the
      // app is in the foreground on Android, where FCM never shows its own
      // notification while the app is open. (iOS presents natively, above.)
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
        if (notification == null || apns) return;
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

  /// Polls for the APNs device token for up to five seconds. If it still
  /// hasn't arrived, the getToken() that follows throws and [_init] resets,
  /// so the next resume or sign-in tries again.
  static Future<void> _waitForApnsToken(FirebaseMessaging messaging) async {
    for (var attempt = 0; attempt < 10; attempt++) {
      if (await messaging.getAPNSToken() != null) return;
      await Future<void>.delayed(const Duration(milliseconds: 500));
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
