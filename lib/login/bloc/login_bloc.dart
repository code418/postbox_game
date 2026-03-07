import 'dart:async';

import 'package:bloc/bloc.dart';
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
    try {
      await _userRepository.signInWithGoogle();
      emit(LoginState.success());
    } catch (_) {
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
      emit(LoginState.success());
    } catch (_) {
      emit(LoginState.failure());
    }
  }
}
