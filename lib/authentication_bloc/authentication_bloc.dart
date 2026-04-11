import 'dart:async';
import 'package:bloc/bloc.dart';
import 'package:postbox_game/authentication_bloc/bloc.dart';
import 'package:postbox_game/user_repository.dart';

class AuthenticationBloc
    extends Bloc<AuthenticationEvent, AuthenticationState?> {
  final UserRepository _userRepository;

  AuthenticationBloc({required UserRepository userRepository})
      : _userRepository = userRepository,
        super(Uninitialized()) {
    on<AppStarted>(_mapAppStartedToState);
    on<LoggedIn>(_mapLoggedInToState);
    on<LoggedOut>(_mapLoggedOutToState);
  }

  Future<void> _mapAppStartedToState(
    AppStarted event,
    Emitter<AuthenticationState?> emit,
  ) async {
    try {
      final isSignedIn = await _userRepository.isSignedIn();
      if (isSignedIn) {
        final name = await _userRepository.getUser();
        emit(Authenticated(name ?? ''));
      } else {
        emit(Unauthenticated());
      }
    } catch (_) {
      emit(Unauthenticated());
    }
  }

  Future<void> _mapLoggedInToState(
    LoggedIn event,
    Emitter<AuthenticationState?> emit,
  ) async {
    emit(Authenticated(await _userRepository.getUser() ?? ''));
  }

  Future<void> _mapLoggedOutToState(
    LoggedOut event,
    Emitter<AuthenticationState?> emit,
  ) async {
    await _userRepository.signOut();
    emit(Unauthenticated());
  }
}
