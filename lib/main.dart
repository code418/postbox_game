import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:postbox_game/authentication_bloc/bloc.dart';
import 'package:postbox_game/claim.dart';
//import 'package:postbox_game/home.dart';
import 'package:postbox_game/intro.dart';
//import 'package:postbox_game/login/login_screen.dart';
import 'package:postbox_game/nearby.dart';
import 'package:postbox_game/signin.dart';
import 'package:postbox_game/splash.dart';
import 'package:postbox_game/upload.dart';
import 'package:postbox_game/user_repository.dart';

void main() {
  //BlocSupervisor.delegate = SimpleBlocDelegate();
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

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => AuthenticationBloc(userRepository: _userRepository)
        ..add(AppStarted()),
      child: MaterialApp(
          home: BlocBuilder<AuthenticationBloc, AuthenticationState>(
            builder: (BuildContext context, AuthenticationState state) {
              if (state is Uninitialized) {
                return Splash();
              }
              /*if (state is Unauthenticated) {
                return LoginScreen(userRepository: _userRepository);
              }
              if (state is Authenticated) {
                return Home();
              }*/
              return Intro();
            },
          ),
          routes: {
            '/login': (context) => SignInPage(),
            '/upload': (context) => Upload(),
            '/nearby': (context) => Nearby(),
            '/Claim': (context) => Claim(),
          }),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
}
