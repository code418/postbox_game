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
      emit(isSignedIn ? const Authenticated() : Unauthenticated());
      if (isSignedIn) {
        // Fire-and-forget: silently repairs accounts created before
        // onUserCreated was deployed (missing Firestore displayName).
        unawaited(_userRepository.backfillDisplayNameIfMissing());
      }
    } catch (_) {
      emit(Unauthenticated());
    }
  }

  Future<void> _mapLoggedInToState(
    LoggedIn event,
    Emitter<AuthenticationState?> emit,
  ) async {
    emit(const Authenticated());
  }

  Future<void> _mapLoggedOutToState(
    LoggedOut event,
    Emitter<AuthenticationState?> emit,
  ) async {
    try {
      await _userRepository.signOut();
    } catch (e) {
      // Sign-out failures (network, platform) must not leave the user
      // stuck in an authenticated state. Always emit Unauthenticated.
      addError(e);
    }
    emit(Unauthenticated());
  }
}
