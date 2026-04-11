import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:postbox_game/app_preferences.dart';
import 'package:postbox_game/authentication_bloc/bloc.dart';
import 'package:postbox_game/intro.dart';
import 'package:postbox_game/theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  DistanceUnit _distanceUnit = DistanceUnit.meters;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final unit = await AppPreferences.getDistanceUnit();
    if (mounted) setState(() => _distanceUnit = unit);
  }

  Future<void> _chooseDistanceUnit() async {
    final chosen = await showModalBottomSheet<DistanceUnit>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
              child: Text('Distance units',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            ListTile(
              title: const Text('Meters'),
              leading: Radio<DistanceUnit>(
                value: DistanceUnit.meters,
                groupValue: _distanceUnit,
                onChanged: (v) => Navigator.pop(context, v),
              ),
              onTap: () => Navigator.pop(context, DistanceUnit.meters),
            ),
            ListTile(
              title: const Text('Miles'),
              leading: Radio<DistanceUnit>(
                value: DistanceUnit.miles,
                groupValue: _distanceUnit,
                onChanged: (v) => Navigator.pop(context, v),
              ),
              onTap: () => Navigator.pop(context, DistanceUnit.miles),
            ),
          ],
        ),
      ),
    );
    if (chosen != null && chosen != _distanceUnit) {
      await AppPreferences.setDistanceUnit(chosen);
      if (mounted) setState(() => _distanceUnit = chosen);
    }
  }

  Future<void> _signOut() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      context.read<AuthenticationBloc>().add(LoggedOut());
    }
  }

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: 'The Postbox Game',
      applicationVersion: '1.0.0',
      applicationLegalese: 'Find postboxes. Claim them. Score mega points.',
      applicationIcon: const Icon(Icons.mail, size: 48, color: postalRed),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final displayName = user?.displayName ?? 'Postbox Hunter';
    final email = user?.email ?? '';

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // Profile header
          Container(
            color: postalRed,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
            ),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: Colors.white,
                  radius: 28,
                  child: Icon(Icons.person, color: postalRed, size: 32),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (email.isNotEmpty)
                        Text(
                          email,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          _sectionHeader('Account'),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            subtitle: const Text('Sign out of your account'),
            onTap: _signOut,
          ),
          const Divider(height: 24),
          _sectionHeader('App'),
          ListTile(
            leading: const Icon(Icons.play_circle_outline),
            title: const Text('Replay intro'),
            subtitle: const Text('Watch the Postman James intro again'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => Intro(replay: true, onDone: () {}),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.straighten),
            title: const Text('Distance units'),
            subtitle:
                Text('Show distances in ${_distanceUnit.label.toLowerCase()}'),
            onTap: _chooseDistanceUnit,
          ),
          const Divider(height: 24),
          _sectionHeader('About'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            subtitle: const Text('Version and app info'),
            onTap: _showAbout,
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.lg, AppSpacing.md, AppSpacing.xs),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
