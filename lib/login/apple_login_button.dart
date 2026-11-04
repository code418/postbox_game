import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:postbox_game/login/bloc/bloc.dart';

/// "Continue with Apple", styled per Apple's Human Interface Guidelines: a
/// black button with the Apple logo, the same size as the Google button so it
/// is at least as prominent (App Review checks this).
class AppleLoginButton extends StatelessWidget {
  const AppleLoginButton({super.key});

  @override
  Widget build(BuildContext context) {
    // Disabled while any sign-in is in flight, like GoogleLoginButton.
    return BlocBuilder<LoginBloc, LoginState>(
      buildWhen: (a, b) => a.isSubmitting != b.isSubmitting,
      builder: (context, state) => OutlinedButton.icon(
        icon: const FaIcon(FontAwesomeIcons.apple, size: 20),
        label: const Text('Continue with Apple'),
        onPressed: state.isSubmitting
            ? null
            : () => context.read<LoginBloc>().add(LoginWithApplePressed()),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          backgroundColor: Colors.black,
          side: const BorderSide(color: Colors.black),
        ),
      ),
    );
  }
}
