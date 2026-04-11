import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:postbox_game/theme.dart';

/// Leaderboard with Daily, Weekly, Monthly tabs.
/// Reads from Firestore leaderboards/{period}; backend can aggregate via Cloud Function.
class LeaderboardScreen extends StatelessWidget {
  const LeaderboardScreen({super.key});

  static const List<String> _periods = ['daily', 'weekly', 'monthly'];

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _periods.length,
      child: Column(
        children: [
          Container(
            color: Theme.of(context).colorScheme.surface,
            child: TabBar(
              tabs: _periods
                  .map((p) => Tab(text: p[0].toUpperCase() + p.substring(1)))
                  .toList(),
            ),
          ),
          Expanded(
            child: TabBarView(
              children: _periods
                  .map((period) => _LeaderboardList(period: period))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _LeaderboardList extends StatefulWidget {
  final String period;

  const _LeaderboardList({required this.period});

  @override
  State<_LeaderboardList> createState() => _LeaderboardListState();
}

class _LeaderboardListState extends State<_LeaderboardList> {
  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _stream;
  final String? _currentUid = FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    _stream = FirebaseFirestore.instance
        .collection('leaderboards')
        .doc(widget.period)
        .snapshots();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, size: 48, color: Colors.grey.shade400),
                const SizedBox(height: AppSpacing.md),
                Text('Could not load leaderboard',
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator(color: postalRed));
        }
        final data = snapshot.data!.data();
        final entries = data?['entries'] as List<dynamic>? ?? [];
        if (entries.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.leaderboard_outlined,
                    size: 72, color: Colors.grey.shade300),
                const SizedBox(height: AppSpacing.md),
                Text('No rankings yet',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        )),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Leaderboard is updated by the backend.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.grey),
                ),
              ],
            ),
          );
        }
        final currentUserInList = _currentUid != null &&
            entries.any((e) =>
                (e as Map<String, dynamic>?)?['uid'] == _currentUid);

        return RefreshIndicator(
          color: postalRed,
          onRefresh: () async {
            // Stream auto-refreshes; this gives user tactile feedback
            await Future.delayed(const Duration(milliseconds: 400));
          },
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            // Extra item at the end when current user is outside the top 100.
            itemCount: entries.length + (currentUserInList ? 0 : 1),
            itemBuilder: (context, index) {
              // Footer row: current user is outside the displayed top 100.
              if (index == entries.length) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.lg),
                  child: Text(
                    'You\'re outside the top ${entries.length} — keep claiming to climb!',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey.shade500,
                        ),
                  ),
                );
              }

              final e = entries[index] as Map<String, dynamic>? ?? {};
              final rank = index + 1;
              final displayName = e['displayName'] as String? ?? 'Unknown';
              final entryUid = e['uid'] as String?;
              final points =
                  (e['points'] is num) ? (e['points'] as num).toInt() : 0;
              final isCurrentUser = entryUid != null && entryUid == _currentUid;

              return Card(
                color: isCurrentUser
                    ? postalRed.withValues(alpha:0.08)
                    : null,
                child: ListTile(
                  leading: _rankWidget(rank),
                  title: Text(
                    displayName,
                    style: isCurrentUser
                        ? const TextStyle(fontWeight: FontWeight.bold)
                        : null,
                  ),
                  trailing: Text(
                    '$points pts',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color:
                              isCurrentUser ? postalRed : Colors.grey.shade600,
                          fontWeight: isCurrentUser
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _rankWidget(int rank) {
    switch (rank) {
      case 1:
        return const Icon(Icons.emoji_events, color: postalGold, size: 32);
      case 2:
        return Icon(Icons.emoji_events, color: Colors.grey.shade400, size: 32);
      case 3:
        return Icon(Icons.emoji_events, color: Colors.brown.shade300, size: 32);
      default:
        return CircleAvatar(
          radius: 16,
          backgroundColor: postalRed.withValues(alpha:0.1),
          child: Text(
            '$rank',
            style: const TextStyle(
                color: postalRed, fontSize: 13, fontWeight: FontWeight.w600),
          ),
        );
    }
  }
}
