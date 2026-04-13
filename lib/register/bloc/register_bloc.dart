import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:firebase_auth/firebase_auth.dart';
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
    emit(state.update(isEmailValid: Validators.isValidEmail(event.email)));
  }

  Future<void> _mapPasswordChangedToState(
    PasswordChanged event,
    Emitter<RegisterState> emit,
  ) async {
    emit(state.update(isPasswordValid: Validators.isValidPassword(event.password)));
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
    } on FirebaseAuthException catch (e) {
      emit(RegisterState.failure(message: _mapFirebaseError(e.code), code: e.code));
    } catch (_) {
      emit(RegisterState.failure());
    }
  }

  static String _mapFirebaseError(String code) {
    switch (code) {
      case 'email-already-in-use':
        return 'An account already exists with that email.';
      case 'invalid-email':
        return 'That email address isn\'t valid.';
      case 'weak-password':
        return 'Password is too weak. Use at least 6 characters.';
      case 'operation-not-allowed':
        return 'Email sign-up is not enabled.';
      case 'network-request-failed':
        return 'No internet connection.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait and try again.';
      default:
        return 'Registration failed. Please try again.';
    }
  }
}
