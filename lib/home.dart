import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:postbox_game/claim.dart';
import 'package:postbox_game/friends_screen.dart';
import 'package:postbox_game/intro.dart';
import 'package:postbox_game/james_controller.dart';
import 'package:postbox_game/james_strip.dart';
import 'package:postbox_game/leaderboard_screen.dart';
import 'package:postbox_game/nearby.dart';
import 'package:postbox_game/theme.dart';

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int _selectedIndex = 0;
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

  // Keep screens alive via IndexedStack
  static const _pages = [
    Nearby(),
    Claim(),
    LeaderboardScreen(),
    FriendsScreen(),
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
                        builder: (_) => Intro(replay: true),
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
            final msg = JamesMessages.forIndex(i);
            if (msg.isNotEmpty) _jamesController.show(msg);
          },
          destinations: _destinations,
          labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
        ),
      ),
    );
  }
}
