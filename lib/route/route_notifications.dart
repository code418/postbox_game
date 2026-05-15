import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Manages local notifications fired when the user arrives at their route
/// destination.
///
/// Backed by [FlutterLocalNotificationsPlugin] with a dedicated
/// "route_arrival" channel (Android) / category (iOS).
///
/// Call [initialise] once at app startup and [requestPermission] from
/// [LiveRouteScreen] when the user begins navigating.
class RouteNotifications {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialised = false;

  static const _channelId = 'route_arrival';
  static const _channelName = 'Route arrival';

  /// Stable notification ID — we only ever show one at a time.
  static const _notificationId = 42;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  /// Initialise the plugin.  Safe to call more than once — subsequent calls
  /// are no-ops.  Call once near app startup (e.g. in [main] after Firebase
  /// initialisation).
  static Future<void> initialise() async {
    if (_initialised) return;
    _initialised = true;

    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      // Do NOT request permissions at init time — we do that explicitly via
      // [requestPermission] to match the existing NotificationService pattern
      // and to give the user a chance to see a rationale first.
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );

    try {
      await _plugin.initialize(settings: initSettings);

      // Create the Android notification channel.
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _channelId,
              _channelName,
              description: 'Shown when you reach your route destination.',
              importance: Importance.high,
            ),
          );
    } catch (_) {
      // Initialisation failures are non-fatal: the in-app arrival flow still
      // works without notifications.
      _initialised = false;
    }
  }

  // ── Permission ─────────────────────────────────────────────────────────────

  /// Request OS notification permission.  Idempotent — safe to call multiple
  /// times.
  ///
  /// Returns [true] if permission is granted (or the platform does not require
  /// an explicit user prompt — e.g. Android < 13).
  static Future<bool> requestPermission() async {
    try {
      // Android 13+ (API 33) — POST_NOTIFICATIONS runtime permission.
      final androidImpl = _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      if (androidImpl != null) {
        final granted = await androidImpl.requestNotificationsPermission();
        return granted ?? false;
      }

      // iOS / macOS.
      final darwinImpl = _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>();
      if (darwinImpl != null) {
        final granted = await darwinImpl.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
        return granted ?? false;
      }

      // Other platforms (e.g. Linux desktop) — assume granted.
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── Fire notification ──────────────────────────────────────────────────────

  /// Fire an arrival notification immediately.
  ///
  /// [destinationLabel] is a human-readable destination name shown in the
  /// body; pass `null` to fall back to "your destination".
  /// [pointsEarned] and [claimedCount] are used to build the notification body.
  static Future<void> notifyArrival({
    required String? destinationLabel,
    required int pointsEarned,
    required int claimedCount,
  }) async {
    final dest = (destinationLabel != null && destinationLabel.isNotEmpty)
        ? destinationLabel
        : 'your destination';

    // Build a human-readable body.
    final pointsPart = '$pointsEarned points earned';
    final body = claimedCount > 0
        ? 'Reached $dest. $pointsPart, $claimedCount postbox${claimedCount == 1 ? '' : 'es'} claimed.'
        : 'Reached $dest. $pointsPart.';

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );

    try {
      await _plugin.show(
        id: _notificationId,
        title: "You're here!",
        body: body,
        notificationDetails: details,
      );
    } catch (_) {
      // Notification failure is non-fatal: the in-app completion screen still
      // shows regardless.
    }
  }
}
