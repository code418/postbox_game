import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:postbox_game/login/bloc/bloc.dart';

class GoogleLoginButton extends StatelessWidget {
  const GoogleLoginButton({super.key});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      icon: const Icon(FontAwesomeIcons.google, size: 18),
      label: const Text('Continue with Google'),
      onPressed: () {
        BlocProvider.of<LoginBloc>(context).add(LoginWithGooglePressed());
      },
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFF444444),
        side: const BorderSide(color: Color(0xFFDDDDDD)),
        backgroundColor: Colors.white,
      ),
    );
  }
}
