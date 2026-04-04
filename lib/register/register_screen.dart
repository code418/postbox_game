import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:postbox_game/register/bloc/bloc.dart';
import 'package:postbox_game/register/register_form.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/user_repository.dart';

class RegisterScreen extends StatelessWidget {
  final UserRepository _userRepository;

  RegisterScreen({Key? key, required UserRepository userRepository})
      : _userRepository = userRepository,
        super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create account'),
        backgroundColor: Colors.transparent,
        foregroundColor: postalRed,
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
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  'Join the hunt',
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: postalRed,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Create your account to start collecting postboxes',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.grey.shade600,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.xl),
                RegisterForm(),
                const SizedBox(height: AppSpacing.xl),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
