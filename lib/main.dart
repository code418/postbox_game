import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:postbox_game/authentication_bloc/bloc.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/claim.dart';
import 'package:postbox_game/claim_history_screen.dart';
import 'package:postbox_game/friends_screen.dart';
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
import 'package:home_widget/home_widget.dart';
import 'firebase_options.dart';
import 'secrets.dart';
import 'analytics_service.dart';
import 'package:postbox_game/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await FirebaseAppCheck.instance.activate(
    providerWeb: ReCaptchaV3Provider(kRecaptchaSiteKey),
    // Debug provider is only safe for local development; release builds must use
    // Play Integrity to actually enforce App Check.
    providerAndroid: kDebugMode
        ? const AndroidDebugProvider()
        : const AndroidPlayIntegrityProvider(),
    providerApple: const AppleAppAttestProvider(),
  );
  await HomeWidgetService.init();
  await _checkInitialWidgetLaunch();
  runApp(const PostboxGame());
}

/// True when the process was launched from the home-screen widget deep link
/// (postbox://claim?source=widget). Consumed once by [_PostboxGameState] to
/// open the Claim tab and auto-scan, then cleared.
bool _pendingWidgetAutoScan = false;

Future<void> _checkInitialWidgetLaunch() async {
  try {
    final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
    if (uri != null && uri.host == 'claim' &&
        uri.queryParameters['source'] == 'widget') {
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

class _PostboxGameState extends State<PostboxGame> {
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
    // Consume the one-shot flag so a cold-start deep-link fires a single
    // auto-scan. Subsequent widget taps (while the app is in memory) are
    // handled by the widgetClicked stream below.
    _pendingWidgetAutoScan = false;
    try {
      _widgetClickSub = HomeWidget.widgetClicked.listen((uri) {
        if (uri != null && uri.host == 'claim' &&
            uri.queryParameters['source'] == 'widget') {
          setState(() => _autoScanEpoch++);
        }
      });
    } catch (_) {
      // home_widget unsupported on this platform.
    }
  }

  @override
  void dispose() {
    _widgetClickSub?.cancel();
    super.dispose();
  }

  /// Redirects to login when accessing protected named routes while unauthenticated.
  /// Uses BlocBuilder so the route rebuilds if auth state changes after it is first pushed
  /// (e.g. deep-linking to a protected URL before the auth check has completed).
  Widget _guardRoute(BuildContext context, Widget Function() page) {
    return BlocBuilder<AuthenticationBloc, AuthenticationState?>(
      builder: (context, state) {
        if (state is Authenticated) return page();
        if (state is Unauthenticated) return LoginScreen(userRepository: _userRepository);
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
              } else if (state is Unauthenticated) {
                unawaited(NotificationService.reset());
                unawaited(_homeWidgetService.refresh());
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
                if (_autoScanEpoch > 0) {
                  // Keying on the epoch forces a fresh Home + Claim mount on
                  // each widget tap. Without the key, Flutter reconciles the
                  // existing _HomeState whose `late final _pages` was built
                  // with autoScan=false, so the new props are ignored and no
                  // scan fires.
                  return Home(
                    key: ValueKey('claim-widget-$_autoScanEpoch'),
                    initialIndex: 1,
                    autoScan: true,
                  );
                }
                return const Home();
              }
              return const Splash();
            },
          ),
          routes: {
            '/nearby': (context) => _guardRoute(context, () => const Nearby()),
            '/claim': (context) => _guardRoute(context, () => const Claim()),
            '/friends': (context) => _guardRoute(context, () => const FriendsScreen()),
            '/leaderboard': (context) => _guardRoute(context, () => const LeaderboardScreen()),
            '/history': (context) => _guardRoute(context, () => const ClaimHistoryScreen()),
            '/settings': (context) => _guardRoute(context, () => const SettingsScreen()),
          }),
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
          if (mounted) setState(() => _introSeen = true);
        },
      );
    }
    return LoginScreen(userRepository: widget._userRepository);
  }
}
