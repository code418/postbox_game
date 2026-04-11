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
import 'package:postbox_game/splash.dart';
import 'package:postbox_game/user_repository.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await FirebaseAppCheck.instance.activate(
    providerWeb: ReCaptchaV3Provider('recaptcha-v3-site-key'),
    providerAndroid: const AndroidDebugProvider(),
    providerApple: const AppleAppAttestProvider(),
  );
  runApp(const PostboxGame());
}

class PostboxGame extends StatefulWidget {
  const PostboxGame({super.key});

  @override
  State<PostboxGame> createState() => _PostboxGameState();
}

class _PostboxGameState extends State<PostboxGame> {
  final UserRepository _userRepository = UserRepository();

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
            '/nearby': (context) => Nearby(),
            '/Claim': (context) => Claim(),
            '/friends': (context) => const FriendsScreen(),
            '/leaderboard': (context) => const LeaderboardScreen(),
            '/settings': (context) => const SettingsScreen(),
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
