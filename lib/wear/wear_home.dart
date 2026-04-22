import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:postbox_game/authentication_bloc/bloc.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/wear/wear_claim_page.dart';
import 'package:postbox_game/wear/wear_compass_page.dart';
import 'package:postbox_game/wear/wear_status_page.dart';
import 'package:postbox_game/wear/wear_theme.dart';

/// Main Wear OS shell — a horizontal [PageView] with three swipeable pages:
/// Compass, Claim, and Status.
///
/// A dot indicator at the bottom shows which page is active. The rotary crown
/// (if available) can also be used to switch pages.
class WearHome extends StatefulWidget {
  const WearHome({super.key});

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
                const WearClaimPage(),
                WearStatusPage(onLogout: _handleLogout),
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
                        : Colors.white.withValues(alpha: 0.3),
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
