import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:postbox_game/authentication_bloc/bloc.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/user_repository.dart';
import 'package:postbox_game/wear/wear_claim_page.dart';
import 'package:postbox_game/wear/wear_compass_page.dart';
import 'package:postbox_game/wear/wear_login_screen.dart';
import 'package:postbox_game/wear/wear_status_page.dart';
import 'package:postbox_game/wear/wear_theme.dart';

/// Main Wear OS shell — a vertical [PageView] with three swipeable pages:
/// Compass, Claim, and Status (or Sign-in when signed out).
///
/// Paging is vertical because Wear OS reserves the left-to-right swipe as
/// the system dismiss gesture — with horizontal paging, swiping "back" threw
/// the user out to the watchface.
///
/// A dot indicator on the right edge shows which page is active. The rotary
/// crown (if available) can also be used to switch pages.
///
/// Signed out, the compass and claim-page scans still work (discovery is
/// auth-free); the third page becomes the Google sign-in screen, and the claim
/// page's CTA jumps there instead of claiming. The parent keys this widget by
/// uid, so an auth change rebuilds the whole shell with fresh page state.
class WearHome extends StatefulWidget {
  const WearHome({
    super.key,
    required this.signedIn,
    required this.userRepository,
  });

  final bool signedIn;
  final UserRepository userRepository;

  @override
  State<WearHome> createState() => _WearHomeState();
}

class _WearHomeState extends State<WearHome> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  static const _pageCount = 3;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    setState(() => _currentPage = index);
  }

  void _handleLogout() {
    context.read<AuthenticationBloc>().add(LoggedOut());
  }

  /// Swipes to the last page, which hosts the sign-in screen while signed
  /// out. Used by the claim page's "Sign in to claim" CTA.
  void _goToSignInPage() {
    _pageController.animateToPage(
      _pageCount - 1,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  /// Rotary crown / bezel ticks navigate whole pages.
  ///
  /// Registered with the [PointerSignalResolver] from a [Listener] INSIDE
  /// each page: pointer signals are resolved cooperatively (first registrant
  /// on the hit-test path wins, deepest first), and the vertical [PageView]'s
  /// own Scrollable also registers for vertical scroll deltas. Its raw
  /// handling nudges the pager by the tick's pixel delta and snaps straight
  /// back, so it must be preempted — which an outer Listener cannot do.
  void _handleRotaryTick(PointerSignalEvent event) {
    final delta = (event as PointerScrollEvent).scrollDelta.dy;
    if (delta > 0 && _currentPage < _pageCount - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else if (delta < 0 && _currentPage > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  Widget _rotaryPage(Widget child) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          GestureBinding.instance.pointerSignalResolver
              .register(event, _handleRotaryTick);
        }
      },
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView(
            // Vertical: Wear OS owns the left-to-right swipe (system
            // dismiss back to the watchface), so horizontal paging fights
            // the OS and loses — a "previous page" swipe would exit the
            // app instead.
            scrollDirection: Axis.vertical,
            controller: _pageController,
            onPageChanged: _onPageChanged,
            children: [
              _rotaryPage(const WearCompassPage()),
              _rotaryPage(WearClaimPage(
                signedIn: widget.signedIn,
                onSignInRequested: _goToSignInPage,
              )),
              _rotaryPage(widget.signedIn
                  ? WearStatusPage(onLogout: _handleLogout)
                  : WearLoginScreen(userRepository: widget.userRepository)),
            ],
          ),

          // Dot indicator — a vertical column on the right edge (the Wear
          // position-indicator spot), matching the vertical paging axis.
          Positioned(
            top: 0,
            bottom: 0,
            right: WearSpacing.lg,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_pageCount, (i) {
                final isActive = i == _currentPage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin:
                      const EdgeInsets.symmetric(vertical: WearSpacing.xs),
                  width: isActive ? 8 : 6,
                  height: isActive ? 8 : 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isActive
                        ? postalRed
                        : Colors.white.withValues(alpha: 0.6),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}
