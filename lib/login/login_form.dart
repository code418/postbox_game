import 'dart:io' show Platform;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:postbox_game/authentication_bloc/bloc.dart';
import 'package:postbox_game/login/bloc/bloc.dart';
import 'package:postbox_game/login/create_account_button.dart';
import 'package:postbox_game/login/google_login_button.dart';
import 'package:postbox_game/login/login_button.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/user_repository.dart';

class LoginForm extends StatefulWidget {
  final UserRepository _userRepository;

  const LoginForm({super.key, required UserRepository userRepository})
      : _userRepository = userRepository;

  @override
  State<LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends State<LoginForm> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _obscurePassword = true;

  late LoginBloc _loginBloc;

  UserRepository get _userRepository => widget._userRepository;

  bool get isPopulated =>
      _emailController.text.isNotEmpty && _passwordController.text.isNotEmpty;

  bool isLoginButtonEnabled(LoginState state) {
    return state.isFormValid && isPopulated && !state.isSubmitting;
  }

  @override
  void initState() {
    super.initState();
    _loginBloc = BlocProvider.of<LoginBloc>(context);
    _emailController.addListener(_onEmailChanged);
    _passwordController.addListener(_onPasswordChanged);
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener(
      bloc: _loginBloc,
      listener: (BuildContext context, LoginState state) {
        if (!context.mounted) return;
        if (state.isFailure) {
          // Analytics.loginFailed() is fired inside LoginBloc (where the method is known).
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(state.errorMessage),
                backgroundColor: Colors.red.shade700,
              ),
            );
        }
        if (state.isSuccess) {
          // Analytics.login() is fired inside LoginBloc (where the method is known).
          BlocProvider.of<AuthenticationBloc>(context).add(LoggedIn());
        }
      },
      child: BlocBuilder(
        bloc: _loginBloc,
        builder: (BuildContext context, LoginState state) {
          return Stack(
            children: [
              Form(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    TextFormField(
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      controller: _emailController,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.email_outlined),
                        labelText: 'Email',
                      ),
                      autocorrect: false,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) =>
                          FocusScope.of(context).nextFocus(),
                      validator: (_) {
                        return !state.isEmailValid ? 'Invalid email address' : null;
                      },
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      controller: _passwordController,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.lock_outline),
                        labelText: 'Password',
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                          onPressed: () => setState(
                              () => _obscurePassword = !_obscurePassword),
                        ),
                      ),
                      obscureText: _obscurePassword,
                      autocorrect: false,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) {
                        if (isLoginButtonEnabled(state)) _onFormSubmitted();
                      },
                      validator: (_) {
                        return !state.isPasswordValid
                            ? 'Password must be at least 6 characters'
                            : null;
                      },
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: state.isSubmitting ? null : _onForgotPassword,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        child: const Text('Forgot password?'),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    LoginButton(
                      onPressed: isLoginButtonEnabled(state)
                          ? _onFormSubmitted
                          : null,
                    ),
                    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) ...[
                      const SizedBox(height: AppSpacing.sm),
                      const GoogleLoginButton(),
                    ],
                    const SizedBox(height: AppSpacing.sm),
                    CreateAccountButton(userRepository: _userRepository),
                  ],
                ),
              ),
              if (state.isSubmitting)
                Positioned.fill(
                  child: Container(
                    color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.7),
                    child: const Center(
                      child: CircularProgressIndicator(color: postalRed),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _onForgotPassword() async {
    final emailController =
        TextEditingController(text: _emailController.text.trim());
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Reset password'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                    'Enter your email address and we\'ll send you a link to reset your password.'),
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                controller: emailController,
                autofocus: emailController.text.isEmpty,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) {
                  // Defer pop by one frame to avoid the '_dependents.isEmpty'
                  // assertion that fires when the keyboard dismissal (which
                  // triggers MediaQuery viewport rebuilds) races with the
                  // dialog being torn down synchronously from this callback.
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) Navigator.of(context).pop(true);
                  });
                },
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.email_outlined),
                ),
              ),
            ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) Navigator.of(context).pop(false);
                });
              },
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) Navigator.of(context).pop(true);
                });
              },
              child: const Text('Send link'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final email = emailController.text.trim();
      if (email.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter your email address.')),
        );
        return;
      }
      await widget._userRepository.sendPasswordResetEmail(email);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
                'If that address is registered, a reset link is on its way.'),
          ),
        );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      // user-not-found must NOT be surfaced as an error: doing so lets an
      // attacker probe whether an email is registered. Show the same generic
      // success message as for a real send so the two cases are
      // indistinguishable on the client.
      if (e.code == 'user-not-found') {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text(
                  'If that address is registered, a reset link is on its way.'),
            ),
          );
        return;
      }
      final msg = e.code == 'invalid-email'
          ? 'That email address isn\'t valid.'
          : 'Could not send reset email. Please try again.';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(msg),
          backgroundColor: Colors.red.shade700,
        ));
    } finally {
      emailController.dispose();
    }
  }

  void _onEmailChanged() {
    _loginBloc.add(EmailChanged(email: _emailController.text));
  }

  void _onPasswordChanged() {
    _loginBloc.add(PasswordChanged(password: _passwordController.text));
  }

  void _onFormSubmitted() {
    _loginBloc.add(
      LoginWithCredentialsPressed(
        email: _emailController.text,
        password: _passwordController.text,
      ),
    );
  }
}
