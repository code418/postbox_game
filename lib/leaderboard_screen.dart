import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:postbox_game/james_controller.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/theme.dart';

/// Leaderboard with Daily, Weekly, Monthly, Lifetime tabs.
/// Reads from Firestore leaderboards/{period}; backend aggregates via Cloud Function.
class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen>
    with SingleTickerProviderStateMixin {
  static const List<String> _periods = ['daily', 'weekly', 'monthly', 'lifetime'];
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _periods.length, vsync: this);
    _tabController.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    if (_tabController.index == _periods.indexOf('lifetime')) {
      JamesController.of(context)
          ?.show(JamesMessages.navLifetimeScores.resolve());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          color: Theme.of(context).colorScheme.surface,
          child: TabBar(
            controller: _tabController,
            tabs: _periods
                .map((p) => Tab(text: p[0].toUpperCase() + p.substring(1)))
                .toList(),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: _periods
                .map((period) => _LeaderboardList(period: period))
                .toList(),
          ),
        ),
      ],
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

  bool get _isLifetime => widget.period == 'lifetime';

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
                Icon(Icons.error_outline, size: 48,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                Icon(Icons.leaderboard_outlined, size: 72,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.2)),
                const SizedBox(height: AppSpacing.md),
                Text('No rankings yet',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        )),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  _isLifetime
                      ? 'Start claiming postboxes to appear here.'
                      : 'No rankings yet — start claiming postboxes to appear here.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          );
        }
        final currentUserInList = _currentUid != null &&
            entries.any((e) =>
                e is Map && e['uid'] == _currentUid);
        // Only show the "outside the top N" footer when authenticated but not
        // in the list; omit it for unauthenticated viewers.
        final showFooter = _currentUid != null && !currentUserInList;

        return RefreshIndicator(
          color: postalRed,
          onRefresh: () async {
            // Stream auto-refreshes; this gives user tactile feedback
            await Future.delayed(const Duration(milliseconds: 400));
          },
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            // Extra item at the end when authenticated user is outside the list.
            itemCount: entries.length + (showFooter ? 1 : 0),
            itemBuilder: (context, index) {
              // Footer row: authenticated user is outside the displayed entries.
              if (index == entries.length) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.lg),
                  child: Text(
                    _isLifetime
                        ? 'You\'re outside the top ${entries.length} — keep exploring!'
                        : 'You\'re outside the top ${entries.length} — keep claiming to climb!',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                );
              }

              final e = (entries[index] is Map<String, dynamic>
                  ? entries[index] as Map<String, dynamic>
                  : const <String, dynamic>{});
              final rank = index + 1;
              final displayName = e['displayName'] as String? ?? 'Unknown';
              final entryUid = e['uid'] as String?;
              final isCurrentUser = entryUid != null && entryUid == _currentUid;

              // Lifetime-specific fields
              final uniqueBoxes = _isLifetime
                  ? ((e['uniquePostboxesClaimed'] is num)
                      ? (e['uniquePostboxesClaimed'] as num).toInt()
                      : 0)
                  : 0;
              final totalPoints = _isLifetime
                  ? ((e['totalPoints'] is num)
                      ? (e['totalPoints'] as num).toInt()
                      : 0)
                  : 0;

              // Standard period fields
              final points = !_isLifetime
                  ? ((e['points'] is num) ? (e['points'] as num).toInt() : 0)
                  : 0;

              final trailingText = _isLifetime
                  ? '$uniqueBoxes ${uniqueBoxes == 1 ? 'box' : 'boxes'} · $totalPoints pts'
                  : '$points pts';

              return Card(
                color: isCurrentUser
                    ? postalRed.withValues(alpha: 0.08)
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
                    trailingText,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: isCurrentUser
                              ? postalRed
                              : Theme.of(context).colorScheme.onSurfaceVariant,
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
          backgroundColor: postalRed.withValues(alpha: 0.1),
          child: Text(
            '$rank',
            style: const TextStyle(
                color: postalRed, fontSize: 13, fontWeight: FontWeight.w600),
          ),
        );
    }
  }
}
