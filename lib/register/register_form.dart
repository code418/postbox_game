import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:postbox_game/authentication_bloc/bloc.dart';
import 'package:postbox_game/register/bloc/bloc.dart';
import 'package:postbox_game/register/register_button.dart';
import 'package:postbox_game/theme.dart';

class RegisterForm extends StatefulWidget {
  const RegisterForm({super.key});

  @override
  State<RegisterForm> createState() => _RegisterFormState();
}

class _RegisterFormState extends State<RegisterForm> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _obscurePassword = true;

  late RegisterBloc _registerBloc;

  bool get isPopulated =>
      _emailController.text.isNotEmpty && _passwordController.text.isNotEmpty;

  bool isRegisterButtonEnabled(RegisterState state) {
    return state.isFormValid && isPopulated && !state.isSubmitting;
  }

  @override
  void initState() {
    super.initState();
    _registerBloc = BlocProvider.of<RegisterBloc>(context);
    _emailController.addListener(_onEmailChanged);
    _passwordController.addListener(_onPasswordChanged);
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener(
      bloc: _registerBloc,
      listener: (BuildContext context, RegisterState state) {
        if (!context.mounted) return;
        if (state.isSuccess) {
          // Analytics.signUp() is fired inside RegisterBloc (where the method is known).
          BlocProvider.of<AuthenticationBloc>(context).add(LoggedIn());
          // Do NOT pop here: LoggedIn() → Authenticated emitted by AuthenticationBloc
          // causes main.dart's BlocBuilder to replace the entire tree with Home.
          // Any Navigator.pop/popUntil call before that rebuild fires would briefly
          // surface the LoginScreen for one frame (same issue as fixed in session 13).
        }
        if (state.isFailure) {
          // Analytics.signUpFailed() is fired inside RegisterBloc (where the error code is known).
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(state.errorMessage),
                backgroundColor: Colors.red.shade700,
              ),
            );
        }
      },
      child: BlocBuilder(
        bloc: _registerBloc,
        builder: (BuildContext context, RegisterState state) {
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
                        helperText: 'At least 6 characters',
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
                        if (isRegisterButtonEnabled(state)) _onFormSubmitted();
                      },
                      validator: (_) {
                        return !state.isPasswordValid
                            ? 'Password must be at least 6 characters'
                            : null;
                      },
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    RegisterButton(
                      onPressed: isRegisterButtonEnabled(state)
                          ? _onFormSubmitted
                          : null,
                    ),
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

  void _onEmailChanged() {
    _registerBloc.add(EmailChanged(email: _emailController.text));
  }

  void _onPasswordChanged() {
    _registerBloc.add(PasswordChanged(password: _passwordController.text));
  }

  void _onFormSubmitted() {
    _registerBloc.add(
      Submitted(
        email: _emailController.text,
        password: _passwordController.text,
      ),
    );
  }
}
