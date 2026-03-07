import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:postbox_game/authentication_bloc/bloc.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/claim.dart';
import 'package:postbox_game/friends_screen.dart';
import 'package:postbox_game/home.dart';
import 'package:postbox_game/leaderboard_screen.dart';
import 'package:postbox_game/intro.dart';
import 'package:postbox_game/intro_preferences.dart';
import 'package:postbox_game/login/login_screen.dart';
import 'package:postbox_game/nearby.dart';
import 'package:postbox_game/settings_screen.dart';
import 'package:postbox_game/signin.dart';
import 'package:postbox_game/splash.dart';
import 'package:postbox_game/upload.dart';
import 'package:postbox_game/user_repository.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'firebase_options.dart';

void main() async{
  //BlocSupervisor.delegate = SimpleBlocDelegate();
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await FirebaseAppCheck.instance.activate(
    // You can also use a `ReCaptchaEnterpriseProvider` provider instance as an
    // argument for `webProvider`
    webProvider: ReCaptchaV3Provider('recaptcha-v3-site-key'),
    // Default provider for Android is the Play Integrity provider. You can use the "AndroidProvider" enum to choose
    // your preferred provider. Choose from:
    // 1. Debug provider
    // 2. Safety Net provider
    // 3. Play Integrity provider
    androidProvider: AndroidProvider.debug,
    // Default provider for iOS/macOS is the Device Check provider. You can use the "AppleProvider" enum to choose
    // your preferred provider. Choose from:
    // 1. Debug provider
    // 2. Device Check provider
    // 3. App Attest provider
    // 4. App Attest provider with fallback to Device Check provider (App Attest provider is only available on iOS 14.0+, macOS 14.0+)
    appleProvider: AppleProvider.appAttest,
  );
  runApp(PostboxGame());
}

class PostboxGame extends StatefulWidget {
  State<PostboxGame> createState() => _PostboxGameState();
}

class _PostboxGameState extends State<PostboxGame> {
  final UserRepository _userRepository = UserRepository();
  //AuthenticationBloc _authenticationBloc;

  @override
  void initState() {
    super.initState();
  }

  /// Redirects to login when accessing protected routes while unauthenticated.
  Widget _guardRoute(BuildContext context, Widget Function() page) {
    final state = context.read<AuthenticationBloc>().state;
    if (state is Authenticated) return page();
    if (state is Unauthenticated) return LoginScreen(userRepository: _userRepository);
    return Splash(); // Uninitialized or null
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
          home: BlocBuilder<AuthenticationBloc, AuthenticationState?>(
            builder: (BuildContext context, AuthenticationState? state) {
              if (state is Uninitialized) {
                return Splash();
              }
              if (state is Unauthenticated) {
                return _UnauthGate(userRepository: _userRepository);
              }
              if (state is Authenticated) {
                return Home();
              }
              return Splash();
            },
          ),
          routes: {
            '/login': (context) => SignInPage(),
            '/upload': (context) => Upload(),
            '/nearby': (context) => _guardRoute(context, () => Nearby()),
            '/Claim': (context) => _guardRoute(context, () => Claim()),
            '/friends': (context) => const FriendsScreen(),
            '/leaderboard': (context) => const LeaderboardScreen(),
            '/settings': (context) => const SettingsScreen(),
          }),
    );
  }

  @override
  void dispose() {
    super.dispose();
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
    if (_introSeen == null) return Splash();
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
