import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/login/bloc/bloc.dart';
import 'package:postbox_game/user_repository.dart';
import 'package:postbox_game/validators.dart';

class LoginBloc extends Bloc<LoginEvent, LoginState> {
  final UserRepository _userRepository;

  LoginBloc({required UserRepository userRepository})
      : _userRepository = userRepository,
        super(LoginState.empty()) {
    on<EmailChanged>(_mapEmailChangedToState);
    on<PasswordChanged>(_mapPasswordChangedToState);
    on<LoginWithGooglePressed>(_mapLoginWithGooglePressedToState);
    on<LoginWithCredentialsPressed>(_mapLoginWithCredentialsPressedToState);
  }

  Future<void> _mapEmailChangedToState(
    EmailChanged event,
    Emitter<LoginState> emit,
  ) async {
    emit(state.update(
      isEmailValid: Validators.isValidEmail(event.email),
    ));
  }

  Future<void> _mapPasswordChangedToState(
    PasswordChanged event,
    Emitter<LoginState> emit,
  ) async {
    emit(state.update(
      isPasswordValid: Validators.isValidPassword(event.password),
    ));
  }

  Future<void> _mapLoginWithGooglePressedToState(
    LoginWithGooglePressed event,
    Emitter<LoginState> emit,
  ) async {
    emit(LoginState.loading());
    try {
      final user = await _userRepository.signInWithGoogle();
      if (user == null) {
        // User cancelled the Google sign-in dialog
        emit(LoginState.empty());
        return;
      }
      unawaited(Analytics.login(method: 'google'));
      emit(LoginState.success());
    } on FirebaseAuthException catch (e) {
      unawaited(Analytics.loginFailed(method: 'google', errorCode: e.code.isNotEmpty ? e.code : 'unknown'));
      emit(LoginState.failure(message: _mapFirebaseError(e.code), code: e.code));
    } catch (_) {
      unawaited(Analytics.loginFailed(method: 'google', errorCode: 'unknown'));
      emit(LoginState.failure());
    }
  }

  Future<void> _mapLoginWithCredentialsPressedToState(
    LoginWithCredentialsPressed event,
    Emitter<LoginState> emit,
  ) async {
    emit(LoginState.loading());
    try {
      await _userRepository.signInWithCredentials(event.email, event.password);
      unawaited(Analytics.login(method: 'email'));
      emit(LoginState.success());
    } on FirebaseAuthException catch (e) {
      unawaited(Analytics.loginFailed(method: 'email', errorCode: e.code.isNotEmpty ? e.code : 'unknown'));
      emit(LoginState.failure(message: _mapFirebaseError(e.code), code: e.code));
    } catch (_) {
      unawaited(Analytics.loginFailed(method: 'email', errorCode: 'unknown'));
      emit(LoginState.failure());
    }
  }

  static String _mapFirebaseError(String code) {
    switch (code) {
      case 'user-not-found':
        return 'No account found with that email.';
      case 'wrong-password':
        return 'Incorrect password.';
      case 'invalid-email':
        return 'That email address isn\'t valid.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait and try again.';
      case 'network-request-failed':
        return 'No internet connection.';
      case 'invalid-credential':
        return 'Email or password is incorrect.';
      default:
        return 'Sign in failed. Please try again.';
    }
  }
}
