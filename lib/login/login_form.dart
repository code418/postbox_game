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
        if (state.isFailure) {
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
                      validator: (_) {
                        return !state.isPasswordValid
                            ? 'Password must be at least 6 characters'
                            : null;
                      },
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    LoginButton(
                      onPressed: isLoginButtonEnabled(state)
                          ? _onFormSubmitted
                          : null,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    GoogleLoginButton(),
                    const SizedBox(height: AppSpacing.xs),
                    CreateAccountButton(userRepository: _userRepository),
                  ],
                ),
              ),
              if (state.isSubmitting)
                Positioned.fill(
                  child: Container(
                    color: Colors.white.withValues(alpha:0.7),
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
