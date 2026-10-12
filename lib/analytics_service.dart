import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';

import 'package:postbox_game/analytics_user_properties.dart';

/// Thin typed wrapper around [FirebaseAnalytics].
///
/// All methods are static and fire-and-forget — errors are logged in debug
/// mode but never propagated to callers.
class Analytics {
  Analytics._();

  static FirebaseAnalytics _fa = FirebaseAnalytics.instance;

  /// Test seam — let unit tests inject a hand-rolled fake before any call
  /// runs. Mirrors `RemoteConfigService.instance =`'s pattern.
  @visibleForTesting
  static set instance(FirebaseAnalytics fa) => _fa = fa;

  @visibleForTesting
  static FirebaseAnalytics get instance => _fa;

  /// In-memory mirror of every user property the wrapper has set during this
  /// process. FirebaseAnalytics has no "getUserProperty" API on Android/iOS,
  /// so the admin Remote Config debug screen reads this map to verify
  /// on-device which audience values are being reported.
  static final Map<String, String?> _userProperties = <String, String?>{};
  static Map<String, String?> get lastSetUserProperties =>
      Map<String, String?>.unmodifiable(_userProperties);

  // One shared observer for the app lifetime — `navigatorObservers` is read
  // on every MaterialApp build, so a getter that returned a fresh
  // FirebaseAnalyticsObserver each time would create one new observer per
  // PostboxGame rebuild and immediately orphan the previous one. The
  // observer holds RouteObserver subscriber lists, so this is wasted work
  // and a minor memory churn even though it's not a true leak.
  static final FirebaseAnalyticsObserver observer =
      FirebaseAnalyticsObserver(analytics: _fa);

  /// Toggle Analytics collection (GDPR consent gate). Collection starts OFF at
  /// cold boot via the `firebase_analytics_collection_enabled=false` manifest
  /// flag; this is the runtime switch driven by ConsentPreferences.
  static Future<void> setCollectionEnabled(bool enabled) async {
    try {
      await _fa.setAnalyticsCollectionEnabled(enabled);
    } catch (e) {
      debugPrint('Analytics.setCollectionEnabled failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Claim scan events
  // ---------------------------------------------------------------------------

  /// User tapped "Scan" on the Claim screen.
  static Future<void> scanStarted() => _log('scan_started');

  /// Claim scan returned results.
  static Future<void> scanComplete({
    required int count,
    required int claimedToday,
    required int minPoints,
    required int maxPoints,
  }) =>
      _log('scan_complete', {
        'postbox_count': count,
        'claimed_today': claimedToday,
        'min_points': minPoints,
        'max_points': maxPoints,
      });

  /// Claim scan returned zero postboxes in range.
  static Future<void> scanEmpty() => _log('scan_empty');

  // ---------------------------------------------------------------------------
  // Nearby search events
  // ---------------------------------------------------------------------------

  /// User tapped "Find nearby postboxes" on the Nearby screen.
  static Future<void> nearbyStarted() => _log('nearby_started');

  /// Nearby search returned results.
  static Future<void> nearbyComplete({
    required int count,
    required int claimedToday,
    required int minPoints,
    required int maxPoints,
  }) =>
      _log('nearby_complete', {
        'postbox_count': count,
        'claimed_today': claimedToday,
        'min_points': minPoints,
        'max_points': maxPoints,
      });

  /// Nearby search returned zero postboxes in range.
  static Future<void> nearbyEmpty() => _log('nearby_empty');

  // ---------------------------------------------------------------------------
  // Quiz events
  // ---------------------------------------------------------------------------

  /// Quiz screen shown for the given cipher.
  static Future<void> quizStarted({required String cipher}) =>
      _log('quiz_started', {'cipher': cipher});

  /// User picked the correct cipher.
  static Future<void> quizCorrect({required String cipher}) =>
      _log('quiz_correct', {'cipher': cipher});

  /// User picked a wrong cipher.
  static Future<void> quizIncorrect({
    required String correctCipher,
    required String selectedCipher,
  }) =>
      _log('quiz_incorrect', {
        'correct_cipher': correctCipher,
        'selected_cipher': selectedCipher,
      });

  // ---------------------------------------------------------------------------
  // Claim events
  // ---------------------------------------------------------------------------

  /// Claim succeeded.
  static Future<void> claimSuccess({
    required int pointsEarned,
    required int claimedCount,
  }) =>
      _log('claim_success', {
        'points_earned': pointsEarned,
        'claimed_count': claimedCount,
      });

  /// Claim failed for a known reason.
  static Future<void> claimFailed({required String reason}) =>
      _log('claim_failed', {'reason': reason});

  // ---------------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------------

  /// Standard Firebase Analytics login event.
  /// [method] is e.g. 'email' or 'google'.
  static Future<void> login({required String method}) =>
      _fa.logLogin(loginMethod: method);

  /// Login attempt that ended in failure.
  static Future<void> loginFailed({
    required String method,
    required String errorCode,
  }) =>
      _log('login_failed', {'method': method, 'error_code': errorCode});

  /// Standard Firebase Analytics sign_up event (new account created).
  static Future<void> signUp({required String method}) =>
      _fa.logSignUp(signUpMethod: method);

  /// Registration attempt that ended in failure.
  static Future<void> signUpFailed({
    required String method,
    required String errorCode,
  }) =>
      _log('sign_up_failed', {'method': method, 'error_code': errorCode});

  // ---------------------------------------------------------------------------
  // Friends
  // ---------------------------------------------------------------------------

  /// User successfully added a friend by UID.
  static Future<void> friendAdded() => _log('friend_added');

  /// User removed a friend.
  static Future<void> friendRemoved() => _log('friend_removed');

  // ---------------------------------------------------------------------------
  // Growth: sharing, invites, activation (docs/marketing-plan.md §Measurement)
  // ---------------------------------------------------------------------------

  /// Standard Firebase Analytics share event. [contentType] is what was
  /// shared (`invite`, `claim`, `streak`, `route`, `profile`); [itemId] a
  /// coarse label for it (e.g. the cypher for a claim card); [method] the
  /// share target the OS reported, or `unknown`.
  static Future<void> share({
    required String contentType,
    required String itemId,
    String method = 'unknown',
  }) =>
      _fa.logShare(contentType: contentType, itemId: itemId, method: method);

  /// An invite link or code reached the app. [source] is how: `link`
  /// (App Link / Universal Link), `scheme` (the invite page's open-in-app
  /// button) or `typed` (pasted into the Friends field).
  static Future<void> inviteLinkOpened({required String source}) =>
      _log('invite_link_opened', {'source': source});

  /// Outcome of acting on an invite: `accepted`, `declined`,
  /// `already_friends`, `self_invite`, `not_found`, `friend_limit`, `error`.
  /// [referral] is true when the server attributed a new sign-up to it.
  static Future<void> inviteAccepted({
    required String result,
    bool referral = false,
  }) =>
      _log('invite_accepted', {'result': result, 'referral': referral ? 1 : 0});

  /// Standard tutorial_complete: the first-run intro was finished.
  static Future<void> tutorialComplete() => _fa.logTutorialComplete();

  /// The account's first ever successful claim (activation).
  static Future<void> firstClaim() => _log('first_claim');

  /// The guide's pre-prompt before the system notification prompt was
  /// answered. [accepted] says whether the system prompt was then shown.
  static Future<void> notificationPrePrompt({required bool accepted}) =>
      _log('notification_preprompt', {'accepted': accepted ? 1 : 0});

  /// The in-app review flow was requested after [trigger] (`rare_claim`,
  /// `streak`). The OS decides whether a sheet actually appears, so this
  /// counts requests, not impressions.
  static Future<void> reviewPromptRequested({required String trigger}) =>
      _log('review_prompt_requested', {'trigger': trigger});

  // ---------------------------------------------------------------------------
  // Location
  // ---------------------------------------------------------------------------

  /// Location permission permanently denied — user was shown the "Open Settings" prompt.
  static Future<void> locationPermissionPermanentlyDenied() =>
      _log('location_permission_permanently_denied');

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  /// Bottom-nav tab selected (0=Nearby, 1=Claim, 2=Scores, 3=Friends, 4=History).
  static Future<void> tabSelected({required int index, required String name}) =>
      _log('tab_selected', {'tab_index': index, 'tab_name': name});

  // ---------------------------------------------------------------------------
  // Route mode — funnel from preview through navigation to arrival/abandon.
  // ---------------------------------------------------------------------------

  /// User tapped "Start route" on the route preview screen with a usable
  /// preview (count/points loaded). Marks the top of the route-mode funnel.
  static Future<void> routeStarted({
    required int count,
    required int points,
    required String mode, // 'corridor' or 'detour'
    required String pace, // 'walk' or 'jog'
  }) =>
      _log('route_started', {
        'postbox_count': count,
        'points': points,
        'mode': mode,
        'pace': pace,
      });

  /// User reached the destination (auto-arrival inside the 25 m radius).
  /// [walkSeconds] is the elapsed time from "Start route" to arrival.
  static Future<void> routeArrived({
    required int pointsEarned,
    required int claimedCount,
    required int walkSeconds,
  }) =>
      _log('route_arrived', {
        'points_earned': pointsEarned,
        'claimed_count': claimedCount,
        'walk_seconds': walkSeconds,
      });

  /// User confirmed "End route" in the live-route abandon dialog (back gesture
  /// or AppBar close button). Distinguishes drop-offs from arrivals in the
  /// funnel — `claimed_count` lets us tell quick rage-quits ("opened, didn't
  /// move, abandoned") from "walked partway, gave up".
  static Future<void> routeAbandoned({
    required int pointsEarned,
    required int claimedCount,
    required int walkSeconds,
  }) =>
      _log('route_abandoned', {
        'points_earned': pointsEarned,
        'claimed_count': claimedCount,
        'walk_seconds': walkSeconds,
      });

  // ---------------------------------------------------------------------------
  // Problem reports — submission outcomes.
  // ---------------------------------------------------------------------------

  /// User successfully submitted a problem report. [type] is
  /// "missing_postbox" or "wrong_cypher" matching the server's report type.
  /// [photoCount] lets us see how often users attach photos vs file with
  /// just a note.
  static Future<void> reportSubmitted({
    required String type,
    required int photoCount,
  }) =>
      _log('report_submitted', {
        'type': type,
        'photo_count': photoCount,
      });

  /// Report submission failed before the server accepted it (e.g. quota
  /// exceeded, network error, mid-upload failure). [type] same as above;
  /// [reason] is a short error code suitable for grouping in dashboards.
  static Future<void> reportSubmitFailed({
    required String type,
    required String reason,
  }) =>
      _log('report_submit_failed', {
        'type': type,
        'reason': reason,
      });

  // ---------------------------------------------------------------------------
  // User identity & properties (Remote Config audience targeting)
  // ---------------------------------------------------------------------------

  /// Identify the signed-in user to Analytics so Remote Config experiments
  /// can be hashed against a stable id rather than the (rotated) installation
  /// id. Pass null on sign-out.
  static Future<void> setUserId(String? uid) async {
    try {
      await _fa.setUserId(id: uid);
    } catch (e) {
      debugPrint('Analytics.setUserId: $e');
    }
  }

  /// Sets every property in [s] on the Analytics user record, mirroring each
  /// into [lastSetUserProperties] so the admin debug card can render them.
  static Future<void> setUserProperties(UserPropertiesSnapshot s) async {
    for (final entry in s.toMap().entries) {
      await setUserProperty(entry.key, entry.value);
    }
  }

  /// Single-key updater for mutation-point pushes (after a claim, after a
  /// friend is added, etc.). Passing `null` clears the property.
  static Future<void> setUserProperty(String name, String? value) async {
    _userProperties[name] = value;
    try {
      await _fa.setUserProperty(name: name, value: value);
    } catch (e) {
      debugPrint('Analytics.setUserProperty($name): $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  static Future<void> _log(String name, [Map<String, Object>? params]) async {
    try {
      await _fa.logEvent(name: name, parameters: params);
    } catch (e) {
      debugPrint('Analytics._log($name): $e');
    }
  }

  @visibleForTesting
  static void resetUserPropertiesForTest() => _userProperties.clear();
}
