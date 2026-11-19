import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:postbox_game/authentication_bloc/bloc.dart';
import 'package:postbox_game/register/bloc/bloc.dart';
import 'package:postbox_game/register/register_form.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/user_repository.dart';

class RegisterScreen extends StatelessWidget {
  final UserRepository _userRepository;

  const RegisterScreen({super.key, required UserRepository userRepository})
      : _userRepository = userRepository;

  @override
  Widget build(BuildContext context) {
    // main.dart's auth gate swaps MaterialApp's `home` to Home on sign-in, but
    // that only replaces the root route: this screen is pushed on top of it
    // (CreateAccountButton), so it has to leave by itself or the new player
    // is left looking at the finished form. Leave on Authenticated rather
    // than on RegisterState.isSuccess: the gate rebuilds the root route in
    // the same frame, so the login screen never shows on the way out.
    return BlocListener<AuthenticationBloc, AuthenticationState?>(
      listenWhen: (previous, current) =>
          current is Authenticated && previous is! Authenticated,
      listener: (context, _) {
        // Close this route only (and anything above it), not the whole stack:
        // a guarded page the player signed up from, such as a web URL like
        // /#/leaderboard, rebuilds into that page and should be where they
        // land.
        final route = ModalRoute.of(context);
        if (route == null || !route.isActive) return;
        Navigator.of(context)
          ..popUntil((r) => r == route)
          ..pop();
      },
      child: _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create account'),
        backgroundColor: Colors.transparent,
        foregroundColor: Theme.of(context).colorScheme.primary,
        elevation: 0,
      ),
      body: BlocProvider<RegisterBloc>(
        create: (context) => RegisterBloc(userRepository: _userRepository),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Column(
              children: [
                const SizedBox(height: AppSpacing.lg),
                SvgPicture.asset(
                  'assets/postbox.svg',
                  height: 64,
                  colorFilter: const ColorFilter.mode(
                    postalRed,
                    BlendMode.srcIn,
                  ),
                  // Decorative — the "Join the hunt" title carries the meaning.
                  excludeFromSemantics: true,
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  'Join the hunt',
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Create your account to start collecting postboxes',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.xl),
                const RegisterForm(),
                const SizedBox(height: AppSpacing.xl),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
