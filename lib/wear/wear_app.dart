import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:home_widget/home_widget.dart';
import 'package:postbox_game/authentication_bloc/bloc.dart';
import 'package:postbox_game/deep_links.dart';
import 'package:postbox_game/services/crashlytics_helper.dart';
import 'package:postbox_game/services/home_widget_service.dart';
import 'package:postbox_game/user_repository.dart';
import 'package:postbox_game/wear/wear_home.dart';
import 'package:postbox_game/wear/wear_theme.dart';

/// True when the process was launched by a tile or complication tap
/// (`postbox://claim?source=tile|complication`). Consumed once by
/// [_WearPostboxGameState] to open the claim page and auto-scan, then cleared.
bool wearPendingAutoScan = false;

/// Records whether this cold start came from a glanceable surface. Called from
/// `main_wear.dart` before `runApp`.
///
/// The tile's trampoline activity and the complications both launch through
/// `HomeWidgetLaunchIntent`, the same mechanism the phone's home-screen widget
/// uses, so the watch reads the tap back through the same plugin rather than
/// inventing a second deep-link channel.
Future<void> checkInitialWearLaunch() async {
  try {
    final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
    if (isClaimDeepLink(uri)) wearPendingAutoScan = true;
  } catch (_) {
    // home_widget unsupported on this platform; ignore.
  }
}

/// Root widget for the Wear OS build.
///
/// Mirrors the phone [PostboxGame] in `main.dart` but with a dark theme,
/// no named routes, and no intro/onboarding flow.
///
/// Unlike the phone, the watch has NO login wall: signed-out users land
/// straight in [WearHome], where the compass and nearby scans work (the
/// `nearbyPostboxes` callable allows unauthenticated discovery scans).
/// Sign-in lives on [WearHome.signInPageIndex] and is only required to claim.
class WearPostboxGame extends StatefulWidget {
  const WearPostboxGame({super.key});

  @override
  State<WearPostboxGame> createState() => _WearPostboxGameState();
}

class _WearPostboxGameState extends State<WearPostboxGame> {
  final UserRepository _userRepository = UserRepository();
  final HomeWidgetService _homeWidget = HomeWidgetService();
  StreamSubscription<Uri?>? _clickSub;

  /// Bumped on every tile/complication tap. Part of the shell's key, so each
  /// tap remounts [WearHome] with a fresh claim page rather than reconciling
  /// the existing state (whose auto-scan has already fired).
  int _autoScanEpoch = wearPendingAutoScan ? 1 : 0;

  @override
  void initState() {
    super.initState();
    // Consume the one-shot cold-start flag; warm taps arrive on the stream.
    wearPendingAutoScan = false;
    try {
      _clickSub = HomeWidget.widgetClicked.listen((uri) {
        if (isClaimDeepLink(uri)) {
          setState(() => _autoScanEpoch++);
        }
      });
    } catch (_) {
      // home_widget unsupported on this platform.
    }
  }

  @override
  void dispose() {
    _clickSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => AuthenticationBloc(userRepository: _userRepository)
        ..add(AppStarted()),
      child: MaterialApp(
        title: 'Postbox',
        theme: WearTheme.dark,
        debugShowCheckedModeBanner: false,
        // The platform pushes a launch intent's URI into the Navigator as a
        // named route as well as delivering it to the plugin. With no handler
        // that is a fatal (see [unknownRoute] — it crashed the phone on 1.4.0),
        // and a tile tap onto an already-open watch app would hit it.
        onUnknownRoute: unknownRoute,
        home: BlocConsumer<AuthenticationBloc, AuthenticationState?>(
          listener: (context, state) {
            if (state is Authenticated || state is Unauthenticated) {
              // Keep the tile and complications honest across sign-in and
              // sign-out: signed out they must show their signed-out face
              // rather than the previous account's streak.
              unawaited(_homeWidget.refresh());
              unawaited(CrashlyticsHelper.setContext(
                CrashlyticsHelper.keyAuthState,
                state is Authenticated ? 'authenticated' : 'unauthenticated',
              ));
            }
          },
          builder: (context, state) {
            if (state is Authenticated || state is Unauthenticated) {
              final signedIn = state is Authenticated;
              // Key by uid so ANY auth transition (sign-in, sign-out, account
              // switch) remounts the shell: per-user streams (streak, user
              // doc) and cached scan results must never survive into a
              // different account's session. The epoch is in the key for the
              // same reason a tap must not be reconciled away.
              return WearHome(
                key: ValueKey<String>(
                    '${_userRepository.currentUid ?? 'signed-out'}'
                    '-$_autoScanEpoch'),
                signedIn: signedIn,
                userRepository: _userRepository,
                initialPage: _autoScanEpoch > 0 ? WearHome.claimPageIndex : 0,
                autoScan: _autoScanEpoch > 0,
              );
            }
            // Uninitialized or null — show a minimal loading indicator.
            return const Scaffold(
              backgroundColor: Colors.black,
              body: Center(
                child: CircularProgressIndicator(),
              ),
            );
          },
        ),
      ),
    );
  }
}
