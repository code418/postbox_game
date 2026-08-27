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

/// Main Wear OS shell — a horizontal [PageView] with three swipeable pages:
/// Compass, Claim, and Status (or Sign-in when signed out).
///
/// A dot indicator at the bottom shows which page is active. The rotary crown
/// (if available) can also be used to switch pages.
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Respond to rotary crown / bezel scroll events to navigate pages.
          Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                if (event.scrollDelta.dy > 0 &&
                    _currentPage < _pageCount - 1) {
                  _pageController.nextPage(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                  );
                } else if (event.scrollDelta.dy < 0 && _currentPage > 0) {
                  _pageController.previousPage(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                  );
                }
              }
            },
            child: PageView(
              controller: _pageController,
              onPageChanged: _onPageChanged,
              children: [
                const WearCompassPage(),
                WearClaimPage(
                  signedIn: widget.signedIn,
                  onSignInRequested: _goToSignInPage,
                ),
                if (widget.signedIn)
                  WearStatusPage(onLogout: _handleLogout)
                else
                  WearLoginScreen(userRepository: widget.userRepository),
              ],
            ),
          ),

          // Dot indicator
          Positioned(
            left: 0,
            right: 0,
            bottom: WearSpacing.lg,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_pageCount, (i) {
                final isActive = i == _currentPage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin:
                      const EdgeInsets.symmetric(horizontal: WearSpacing.xs),
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
