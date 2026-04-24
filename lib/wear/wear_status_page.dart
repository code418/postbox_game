import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:postbox_game/streak_service.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/wear/wear_theme.dart';

/// Quick status glance for Wear OS — shows streak, lifetime stats, and logout.
class WearStatusPage extends StatefulWidget {
  const WearStatusPage({super.key, required this.onLogout});

  final VoidCallback onLogout;

  @override
  State<WearStatusPage> createState() => _WearStatusPageState();
}

class _WearStatusPageState extends State<WearStatusPage> {
  final StreakService _streakService = StreakService();
  late final Stream<int?> _streakStream = _streakService.streakStream();
  // Cache so the StreamBuilder doesn't re-subscribe (and briefly show empty
  // stats) on every rebuild. Computed once in initState from the uid at mount.
  late final Stream<DocumentSnapshot<Map<String, dynamic>>>? _userDocStream =
      _buildUserDocStream();

  String? get _displayName => FirebaseAuth.instance.currentUser?.displayName;

  Stream<DocumentSnapshot<Map<String, dynamic>>>? _buildUserDocStream() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    return FirebaseFirestore.instance.collection('users').doc(uid).snapshots();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: WearSpacing.xl,
            vertical: WearSpacing.lg,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Display name
              if (_displayName != null)
                Text(
                  _displayName!,
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              const SizedBox(height: WearSpacing.lg),

              // Streak
              StreamBuilder<int?>(
                stream: _streakStream,
                builder: (context, snap) {
                  final streak = snap.data ?? 0;
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('🔥', style: TextStyle(fontSize: 16)),
                      const SizedBox(width: 4),
                      Text(
                        streak > 0 ? '$streak-day streak' : 'No streak',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: WearSpacing.sm),

              // Lifetime points
              StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: _userDocStream,
                builder: (context, snap) {
                  final data = snap.data?.data();
                  final lifetimePoints =
                      (data?['lifetimePoints'] as num?)?.toInt() ?? 0;
                  final uniqueClaimed =
                      (data?['uniquePostboxesClaimed'] as num?)?.toInt() ?? 0;
                  return Column(
                    children: [
                      _statRow(context, Icons.stars, '$lifetimePoints pts'),
                      const SizedBox(height: WearSpacing.xs),
                      _statRow(
                          context, Icons.pin_drop, '$uniqueClaimed claimed'),
                    ],
                  );
                },
              ),

              const SizedBox(height: WearSpacing.lg),
              TextButton.icon(
                onPressed: widget.onLogout,
                icon: const Icon(Icons.logout, size: 14),
                label: const Text('Sign out'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statRow(BuildContext context, IconData icon, String label) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: postalGold),
        const SizedBox(width: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }
}
