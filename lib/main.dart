import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:postbox_game/authentication_bloc/bloc.dart';
import 'package:postbox_game/services/claim_outbox.dart';
import 'package:postbox_game/services/connectivity_service.dart';
import 'package:postbox_game/services/outbox_sync.dart';
import 'package:postbox_game/services/scan_cache.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/claim.dart';
import 'package:postbox_game/claim_history_screen.dart';
import 'package:postbox_game/friends_screen.dart';
import 'package:postbox_game/consent_screen.dart';
import 'package:postbox_game/home.dart';
import 'package:postbox_game/leaderboard_screen.dart';
import 'package:postbox_game/intro.dart';
import 'package:postbox_game/intro_preferences.dart';
import 'package:postbox_game/login/login_screen.dart';
import 'package:postbox_game/nearby.dart';
import 'package:postbox_game/services/home_widget_service.dart';
import 'package:postbox_game/settings_screen.dart';
import 'package:postbox_game/splash.dart';
import 'package:postbox_game/user_repository.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:home_widget/home_widget.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'dart:io' show Platform;
import 'firebase_options.dart';
import 'oauth_client_ids.dart';
import 'secrets.dart';
import 'analytics_service.dart';
import 'package:postbox_game/admin/admin_access.dart';
import 'package:postbox_game/analytics_user_properties.dart';
import 'package:postbox_game/notification_service.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/services/crashlytics_helper.dart';
import 'package:postbox_game/services/telemetry_consent.dart';
import 'package:postbox_game/route/destination_picker_screen.dart';
import 'package:postbox_game/route/route_notifications.dart';
import 'package:postbox_game/services/user_properties_publisher.dart';
import 'package:firebase_auth/firebase_auth.dart';

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
  // Route uncaught framework + platform errors to Crashlytics as fatals —
  // except image-resource failures (offline map tiles), which are downgraded to
  // a deduped non-fatal so a blank tile doesn't read as a crash. See
  // [CrashlyticsHelper.reportFlutterError].
  FlutterError.onError = CrashlyticsHelper.reportFlutterError;
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };
  // Apply the stored GDPR telemetry consent to Analytics/Crashlytics/Perf in
  // one place (analytics is opt-in and starts manifest-disabled; crash/perf
  // are legitimate-interest with Settings opt-outs, still off in debug).
  unawaited(applyStoredTelemetryPreferences());
  try {
    await FirebaseAppCheck.instance.activate(
      providerWeb: ReCaptchaV3Provider(kRecaptchaSiteKey),
      // Debug provider is only safe for local development; release builds must use
      // Play Integrity to actually enforce App Check.
      providerAndroid: kDebugMode
          ? const AndroidDebugProvider()
          : const AndroidPlayIntegrityProvider(),
      providerApple: const AppleAppAttestProvider(),
    );
  } catch (e, st) {
    // An App Check provider/token failure shouldn't block launch — record it as
    // a non-fatal (deduped: provider outages would otherwise spam every start).
    unawaited(CrashlyticsHelper.recordHandled(e, st,
        reason: 'app_check_activate', dedupeKey: 'app_check_activate'));
  }
  // google_sign_in 7.x needs explicit client IDs to issue an ID token usable
  // by Firebase signInWithCredential. The Web client ID (Firebase Auth's
  // OAuth client of type 3 from google-services.json) doubles as the
  // Android serverClientId. iOS reads the iOS-type client ID from
  // GoogleService-Info.plist when no clientId is passed, but we pass it
  // explicitly so Firebase Auth's iosClientId stays authoritative.
  // Both IDs live in lib/oauth_client_ids.dart so main_wear.dart can share
  // them without duplicating the literals (a drift would break Sign-In on
  // one platform). They are not secrets.
  await GoogleSignIn.instance.initialize(
    clientId: kIsWeb
        ? webClientId
        : (!kIsWeb && Platform.isIOS)
            ? iosClientId
            : null,
    serverClientId: kIsWeb ? null : webClientId,
  );
  await HomeWidgetService.init();
  await _checkInitialWidgetLaunch();
  await RouteNotifications.initialise();
  // Defaults serve immediately; the fetch runs in the background so the splash
  // never blocks on a Remote Config round-trip. Errors are logged and swallowed
  // inside init().
  unawaited(RemoteConfigService.instance.init());
  // Offline play (v1.5): connectivity awareness + auto-flush of banked claims
  // whenever the link returns. Both are best-effort and never block startup.
  unawaited(ConnectivityService.instance.init());
  OutboxSync.instance.start();
  runApp(const PostboxGame());
}

/// Coarse auth-provider label for the Crashlytics `auth_state` key. Never PII —
/// just which sign-in method is active (`google` / `email` / `anon`).
String _authStateLabel(User? user) {
  if (user == null) return 'signed_out';
  if (user.isAnonymous) return 'anon';
  final providers = user.providerData.map((p) => p.providerId).toSet();
  if (providers.contains('google.com')) return 'google';
  if (providers.contains('password')) return 'email';
  return 'unknown';
}

/// True when the process was launched from the home-screen widget deep link
/// (postbox://claim?source=widget). Consumed once by [_PostboxGameState] to
/// open the Claim tab and auto-scan, then cleared.
bool _pendingWidgetAutoScan = false;

/// Whether [uri] is the home-screen widget's claim deep link.
///
/// The Kotlin widget provider fires `postbox://claim?source=widget`
/// (PostboxWidgetProvider.kt DEEP_LINK). Keeping the parsing in one place
/// stops the two call sites below from drifting and gives a single thing
/// to pin in tests against the Kotlin constant.
@visibleForTesting
bool isWidgetClaimDeepLink(Uri? uri) =>
    uri != null &&
    uri.host == 'claim' &&
    uri.queryParameters['source'] == 'widget';

/// Swallow a named route the app doesn't own, instead of crashing.
///
/// The platform pushes intent URIs into the Navigator as named routes
/// (`didPushRouteInformation` → `pushNamed`). The home-screen widget's
/// `postbox://claim?source=widget` arrives that way as `/?source=widget`,
/// which is in neither [routes] nor an `onGenerateRoute` — and with
/// `onUnknownRoute` unset Flutter does `widget.onUnknownRoute!(settings)`,
/// so tapping the widget WHILE THE APP WAS ALREADY OPEN hard-crashed it
/// (Crashlytics `_WidgetsAppState._onUnknownRoute`, fatal, 1.4.0).
///
/// Swallowing is the right answer rather than landing somewhere: the widget
/// tap is already handled properly by the `HomeWidget.widgetClicked` listener
/// in [_PostboxGameState], which opens the Claim tab and auto-scans. This
/// route is the engine's duplicate of that same tap. It must still return a
/// real Route — returning null crashes on the `_routeNamed(...)!` in
/// `pushNamed` — so it returns a transparent one that pops on the first frame.
///
/// Unknown routes are still reported (non-fatally, deduped) so a genuinely
/// broken deep link doesn't just vanish.
@visibleForTesting
Route<void> unknownRoute(RouteSettings settings) {
  unawaited(CrashlyticsHelper.recordHandled(
    StateError('unknown route pushed: ${settings.name}'),
    StackTrace.current,
    reason: 'navigator_unknown_route',
    dedupeKey: 'unknown_route_${settings.name}',
  ));
  return PageRouteBuilder<void>(
    settings: settings,
    opaque: false,
    barrierColor: null,
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    pageBuilder: (_, __, ___) => const _SelfDismissingRoute(),
  );
}

/// Renders nothing and pops itself once mounted. See [unknownRoute].
class _SelfDismissingRoute extends StatefulWidget {
  const _SelfDismissingRoute();

  @override
  State<_SelfDismissingRoute> createState() => _SelfDismissingRouteState();
}

class _SelfDismissingRouteState extends State<_SelfDismissingRoute> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Future<void> _checkInitialWidgetLaunch() async {
  try {
    final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
    if (isWidgetClaimDeepLink(uri)) {
      _pendingWidgetAutoScan = true;
    }
  } catch (_) {
    // Not supported on this platform; ignore.
  }
}

class PostboxGame extends StatefulWidget {
  const PostboxGame({super.key});

  @override
  State<PostboxGame> createState() => _PostboxGameState();
}

class _PostboxGameState extends State<PostboxGame> with WidgetsBindingObserver {
  final UserRepository _userRepository = UserRepository();
  final HomeWidgetService _homeWidgetService = HomeWidgetService();
  StreamSubscription<Uri?>? _widgetClickSub;
  // Monotonic counter of widget-deep-link activations. Each increment is used
  // as part of the Home widget's key so a widget tap while the app is warm
  // (already authenticated) forces a fresh Home + Claim mount rather than
  // re-using the existing _HomeState — the previous _pages/_selectedIndex
  // were initialised from `late final` fields and would otherwise ignore the
  // new autoScan/initialIndex props.
  int _autoScanEpoch = _pendingWidgetAutoScan ? 1 : 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Consume the one-shot flag so a cold-start deep-link fires a single
    // auto-scan. Subsequent widget taps (while the app is in memory) are
    // handled by the widgetClicked stream below.
    _pendingWidgetAutoScan = false;
    try {
      _widgetClickSub = HomeWidget.widgetClicked.listen((uri) {
        if (isWidgetClaimDeepLink(uri)) {
          setState(() => _autoScanEpoch++);
        }
      });
    } catch (_) {
      // home_widget unsupported on this platform.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _widgetClickSub?.cancel();
    super.dispose();
  }

  /// Refresh the Android home-screen widget when the app comes back to the
  /// foreground. Without this, data goes stale across:
  ///   - daily rollover at midnight London (today's points/streak should reset),
  ///   - claims made on the paired Wear OS watch (no path back to the phone
  ///     widget refresh otherwise), and
  ///   - external rescores (e.g. an admin accepting a wrong-cypher report).
  /// Phone-side claims still call refresh() directly for instant feedback.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_homeWidgetService.refresh());
    }
  }

  /// Redirects to login when accessing protected named routes while unauthenticated.
  /// Uses BlocBuilder so the route rebuilds if auth state changes after it is first pushed
  /// (e.g. deep-linking to a protected URL before the auth check has completed).
  Widget _guardRoute(BuildContext context, Widget Function() page) {
    return BlocBuilder<AuthenticationBloc, AuthenticationState?>(
      builder: (context, state) {
        if (state is Authenticated) return page();
        if (state is Unauthenticated) {
          return LoginScreen(userRepository: _userRepository);
        }
        return const Splash();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => AuthenticationBloc(userRepository: _userRepository)
        ..add(AppStarted()),
      child: MaterialApp(
          title: 'The Postbox Game',
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: ThemeMode.system,
          navigatorObservers: [Analytics.observer],
          home: BlocConsumer<AuthenticationBloc, AuthenticationState?>(
            listener: (context, state) {
              if (state is Authenticated) {
                unawaited(NotificationService.init());
                unawaited(_homeWidgetService.refresh());
                // Force a fresh Remote Config fetch on login (bypassing the
                // 1-hour throttle) so a stale client cache can't hide a
                // corrected game-balance value (claim radius / monarch points).
                unawaited(RemoteConfigService.instance.forceRefresh());
                final user = FirebaseAuth.instance.currentUser;
                unawaited(CrashlyticsHelper.setContext(
                    CrashlyticsHelper.keyAuthState, _authStateLabel(user)));
                final uid = user?.uid;
                // The outbox is device-global but user-bound: recount it
                // against whoever just signed in.
                unawaited(ClaimOutbox.instance.refreshOwnership());
                if (uid != null) {
                  unawaited(Analytics.setUserId(uid));
                  unawaited(publishUserPropertiesFromFirestore(uid));
                }
              } else if (state is Unauthenticated) {
                unawaited(NotificationService.reset());
                unawaited(_homeWidgetService.refresh());
                // Forget any admin-claim result cached against the previous
                // uid so a non-admin signing in next on the same device
                // doesn't briefly see the admin entry points.
                AdminAccess.reset();
                // Same reasoning for the offline caches: the scan cache holds
                // the previous user's results and capture token, and the
                // outbox's pending count is per-account.
                ScanCache.clear();
                unawaited(ClaimOutbox.instance.refreshOwnership());
                unawaited(Analytics.setUserId(null));
                unawaited(CrashlyticsHelper.setContext(
                    CrashlyticsHelper.keyAuthState, 'signed_out'));
              }
            },
            builder: (BuildContext context, AuthenticationState? state) {
              if (state is Uninitialized) {
                return const Splash();
              }
              if (state is Unauthenticated) {
                return _UnauthGate(userRepository: _userRepository);
              }
              if (state is Authenticated) {
                // ConsentGate is a pass-through for anyone who has made the
                // analytics choice (new users decide in the intro); existing
                // installs get a one-time consent prompt before Home.
                if (_autoScanEpoch > 0) {
                  // Keying on the epoch forces a fresh Home + Claim mount on
                  // each widget tap. Without the key, Flutter reconciles the
                  // existing _HomeState whose `late final _pages` was built
                  // with autoScan=false, so the new props are ignored and no
                  // scan fires.
                  return ConsentGate(
                    child: Home(
                      key: ValueKey('claim-widget-$_autoScanEpoch'),
                      initialIndex: 1,
                      autoScan: true,
                    ),
                  );
                }
                return const ConsentGate(child: Home());
              }
              return const Splash();
            },
          ),
          routes: {
            '/nearby': (context) => _guardRoute(context, () => const Nearby()),
            '/claim': (context) => _guardRoute(context, () => const Claim()),
            '/friends': (context) =>
                _guardRoute(context, () => const FriendsScreen()),
            '/leaderboard': (context) =>
                _guardRoute(context, () => const LeaderboardScreen()),
            '/history': (context) =>
                _guardRoute(context, () => const ClaimHistoryScreen()),
            '/settings': (context) =>
                _guardRoute(context, () => const SettingsScreen()),
            '/route': (context) =>
                _guardRoute(context, () => const DestinationPickerScreen()),
          },
          onUnknownRoute: unknownRoute),
    );
  }
}

/// Shows intro on first run, then login. Subsequent launches go straight to login.
class _UnauthGate extends StatefulWidget {
  const _UnauthGate({required UserRepository userRepository})
      : _userRepository = userRepository;

  final UserRepository _userRepository;

  @override
  State<_UnauthGate> createState() => _UnauthGateState();
}

class _UnauthGateState extends State<_UnauthGate> {
  bool? _introSeen;

  @override
  void initState() {
    super.initState();
    IntroPreferences.hasSeenIntro().then((seen) {
      if (mounted) setState(() => _introSeen = seen);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_introSeen == null) return const Splash();
    if (_introSeen == false) {
      return Intro(
        replay: false,
        onDone: () async {
          await IntroPreferences.setIntroSeen();
          unawaited(Analytics.setUserProperty(
              AnalyticsUserProps.kHasSeenIntro, 'true'));
          if (mounted) setState(() => _introSeen = true);
        },
      );
    }
    return LoginScreen(userRepository: widget._userRepository);
  }
}
