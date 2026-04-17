import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/claim.dart';
import 'package:postbox_game/friends_screen.dart';
import 'package:postbox_game/intro.dart';
import 'package:postbox_game/james_controller.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/james_strip.dart';
import 'package:postbox_game/leaderboard_screen.dart';
import 'package:postbox_game/nearby.dart';
import 'package:postbox_game/theme.dart';

class Home extends StatefulWidget {
  const Home({super.key, this.initialIndex = 0, this.autoScan = false});

  /// Index of the tab to show on first build. 0=Nearby, 1=Claim, 2=Scores, 3=Friends.
  final int initialIndex;

  /// When true, the Claim tab kicks off a scan automatically on first build.
  /// Used by the Android home-screen widget deep-link.
  final bool autoScan;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  late int _selectedIndex = widget.initialIndex;
  late final JamesController _jamesController = JamesController();

  static const _destinations = [
    NavigationDestination(
      icon: Icon(Icons.location_searching_outlined),
      selectedIcon: Icon(Icons.location_searching),
      label: 'Nearby',
    ),
    NavigationDestination(
      icon: Icon(Icons.add_location_alt_outlined),
      selectedIcon: Icon(Icons.add_location_alt),
      label: 'Claim',
    ),
    NavigationDestination(
      icon: Icon(Icons.leaderboard_outlined),
      selectedIcon: Icon(Icons.leaderboard),
      label: 'Scores',
    ),
    NavigationDestination(
      icon: Icon(Icons.people_outline),
      selectedIcon: Icon(Icons.people),
      label: 'Friends',
    ),
  ];

  // Keep screens alive via IndexedStack. `autoScan` is only forwarded on
  // first build; re-entering the Claim tab later won't retrigger a scan
  // because the widget is preserved by IndexedStack.
  late final List<Widget> _pages = [
    const Nearby(),
    Claim(autoScan: widget.autoScan),
    const LeaderboardScreen(),
    const FriendsScreen(),
  ];

  @override
  void dispose() {
    _jamesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return JamesControllerScope(
      controller: _jamesController,
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SvgPicture.asset(
                'assets/postbox.svg',
                height: 28,
                colorFilter: const ColorFilter.mode(
                  Colors.white,
                  BlendMode.srcIn,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              const Text('Postbox Game'),
            ],
          ),
          actions: [
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (value) {
                switch (value) {
                  case 'settings':
                    Navigator.pushNamed(context, '/settings');
                  case 'intro':
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const Intro(replay: true),
                      ),
                    );
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'settings',
                  child: ListTile(
                    leading: Icon(Icons.settings_outlined),
                    title: Text('Settings'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: 'intro',
                  child: ListTile(
                    leading: Icon(Icons.help_outline),
                    title: Text('How to play'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ],
        ),
        body: Stack(
          children: [
            IndexedStack(
              index: _selectedIndex,
              children: _pages,
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: JamesStrip(controller: _jamesController),
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _selectedIndex,
          onDestinationSelected: (i) {
            setState(() => _selectedIndex = i);
            final tabName = ['nearby', 'claim', 'scores', 'friends'][i];
            Analytics.tabSelected(index: i, name: tabName);
            final msg = JamesMessages.forTabIndex(i);
            if (msg != null) _jamesController.show(msg.resolve());
          },
          destinations: _destinations,
          labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
        ),
      ),
    );
  }
}
