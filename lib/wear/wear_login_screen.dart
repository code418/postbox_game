import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:postbox_game/authentication_bloc/bloc.dart';
import 'package:postbox_game/user_repository.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/wear/wear_theme.dart';

/// Google Sign-In only login screen for Wear OS.
///
/// Email/password input is impractical on a watch, so only the Google
/// sign-in flow is offered. Reuses [UserRepository.signInWithGoogle].
class WearLoginScreen extends StatefulWidget {
  const WearLoginScreen({super.key, required UserRepository userRepository})
      : _userRepository = userRepository;

  final UserRepository _userRepository;

  @override
  State<WearLoginScreen> createState() => _WearLoginScreenState();
}

class _WearLoginScreenState extends State<WearLoginScreen> {
  bool _isLoading = false;
  String? _error;

  Future<void> _signInWithGoogle() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final user = await widget._userRepository.signInWithGoogle();
      if (!mounted) return;
      if (user != null) {
        context.read<AuthenticationBloc>().add(LoggedIn());
      } else {
        // User cancelled the Google Sign-In flow.
        setState(() => _isLoading = false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Sign-in failed';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(WearSpacing.xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SvgPicture.asset(
                'assets/postbox.svg',
                height: 36,
                colorFilter:
                    const ColorFilter.mode(postalRed, BlendMode.srcIn),
              ),
              const SizedBox(height: WearSpacing.lg),
              Text(
                'Postbox Game',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: WearSpacing.xl),
              if (_isLoading)
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                FilledButton.icon(
                  onPressed: _signInWithGoogle,
                  icon: const Icon(Icons.login, size: 16),
                  label: const Text('Google Sign-In'),
                ),
              if (_error != null) ...[
                const SizedBox(height: WearSpacing.sm),
                Text(
                  _error!,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.error),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
