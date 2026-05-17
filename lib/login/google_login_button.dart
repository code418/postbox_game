import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:postbox_game/login/bloc/bloc.dart';
import 'package:postbox_game/theme.dart';

class GoogleLoginButton extends StatelessWidget {
  const GoogleLoginButton({super.key});

  @override
  Widget build(BuildContext context) {
    // Disable while a sign-in is in flight so a second tap can't dispatch
    // another LoginWithGooglePressed (which would re-open the picker on top
    // of the in-progress flow). Matches the LoginButton's isSubmitting guard.
    return BlocBuilder<LoginBloc, LoginState>(
      buildWhen: (a, b) => a.isSubmitting != b.isSubmitting,
      builder: (context, state) => OutlinedButton.icon(
        icon: const FaIcon(FontAwesomeIcons.google, size: 18),
        label: const Text('Continue with Google'),
        onPressed: state.isSubmitting
            ? null
            : () => context.read<LoginBloc>().add(LoginWithGooglePressed()),
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF444444),
          side: const BorderSide(color: AppColors.borderLight),
          backgroundColor: Colors.white,
        ),
      ),
    );
  }
}
