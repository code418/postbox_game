import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:postbox_game/authentication_bloc/bloc.dart';
import 'package:postbox_game/user_repository.dart';
import 'package:postbox_game/wear/wear_home.dart';
import 'package:postbox_game/wear/wear_login_screen.dart';
import 'package:postbox_game/wear/wear_theme.dart';

/// Root widget for the Wear OS build.
///
/// Mirrors the phone [PostboxGame] in `main.dart` but with a dark theme,
/// no named routes, and no intro/onboarding flow.
class WearPostboxGame extends StatefulWidget {
  const WearPostboxGame({super.key});

  @override
  State<WearPostboxGame> createState() => _WearPostboxGameState();
}

class _WearPostboxGameState extends State<WearPostboxGame> {
  final UserRepository _userRepository = UserRepository();

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => AuthenticationBloc(userRepository: _userRepository)
        ..add(AppStarted()),
      child: MaterialApp(
        title: 'Postbox',
        theme: WearTheme.dark,
        debugShowCheckedModeBanner: false,
        home: BlocBuilder<AuthenticationBloc, AuthenticationState?>(
          builder: (context, state) {
            if (state is Authenticated) {
              return const WearHome();
            }
            if (state is Unauthenticated) {
              return WearLoginScreen(userRepository: _userRepository);
            }
            // Uninitialized or null — show a minimal loading indicator.
            return const Scaffold(
              backgroundColor: Colors.black,
              body: Center(
                child: CircularProgressIndicator(),
              ),
            );
          },
        ),
      ),
    );
  }
}
