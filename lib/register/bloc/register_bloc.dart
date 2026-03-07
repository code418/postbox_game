import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:postbox_game/register/bloc/bloc.dart';
import 'package:postbox_game/user_repository.dart';
import 'package:postbox_game/validators.dart';

class RegisterBloc extends Bloc<RegisterEvent, RegisterState> {
  final UserRepository _userRepository;

  RegisterBloc({required UserRepository userRepository})
      : _userRepository = userRepository,
        super(RegisterState.empty()) {
    on<EmailChanged>(_mapEmailChangedToState);
    on<PasswordChanged>(_mapPasswordChangedToState);
    on<Submitted>(_mapFormSubmittedToState);
  }

  Future<void> _mapEmailChangedToState(
    EmailChanged event,
    Emitter<RegisterState> emit,
  ) async {
    emit(state.update(
      isEmailValid: Validators.isValidEmail(event.email),
    ));
  }

  Future<void> _mapPasswordChangedToState(
    PasswordChanged event,
    Emitter<RegisterState> emit,
  ) async {
    emit(state.update(
      isPasswordValid: Validators.isValidPassword(event.password),
    ));
  }

  Future<void> _mapFormSubmittedToState(
    Submitted event,
    Emitter<RegisterState> emit,
  ) async {
    emit(RegisterState.loading());
    try {
      await _userRepository.signUp(
        email: event.email,
        password: event.password,
      );
      emit(RegisterState.success());
    } catch (_) {
      emit(RegisterState.failure());
    }
  }
}
