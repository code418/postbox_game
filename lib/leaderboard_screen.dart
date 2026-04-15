import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:postbox_game/james_controller.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/user_profile_page.dart';

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
  bool _friendsOnly = true;
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
    if (!mounted) return;
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
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: _periods
                .map((p) => Tab(text: p[0].toUpperCase() + p.substring(1)))
                .toList(),
          ),
        ),
        // Friends-only toggle row
        Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.xs),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Friends only',
                  style: Theme.of(context).textTheme.bodyMedium),
              Switch(
                value: _friendsOnly,
                activeColor: postalRed,
                onChanged: (v) => setState(() => _friendsOnly = v),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: _periods.map<Widget>((period) {
              if (_friendsOnly) {
                return _FriendsPeriodList(
                  key: ValueKey('friends_$period'),
                  period: period,
                );
              }
              return _LeaderboardList(
                key: ValueKey('global_$period'),
                period: period,
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}

class _LeaderboardList extends StatefulWidget {
  final String period;

  const _LeaderboardList({super.key, required this.period});

  @override
  State<_LeaderboardList> createState() => _LeaderboardListState();
}

class _LeaderboardListState extends State<_LeaderboardList> {
  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _stream;
  final String? _currentUid = FirebaseAuth.instance.currentUser?.uid;
  int? _totalPostboxes;

  bool get _isLifetime => widget.period == 'lifetime';

  @override
  void initState() {
    super.initState();
    _stream = FirebaseFirestore.instance
        .collection('leaderboards')
        .doc(widget.period)
        .snapshots();
    if (_isLifetime) _loadTotalPostboxes();
  }

  Future<void> _loadTotalPostboxes() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('meta')
          .doc('stats')
          .get();
      final total = (doc.data()?['totalPostboxes'] as num?)?.toInt();
      if (mounted && total != null && total > 0) {
        setState(() => _totalPostboxes = total);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.only(bottom: kJamesStripClearance),
            child: Center(
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
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.only(bottom: kJamesStripClearance),
            child: Center(child: CircularProgressIndicator(color: postalRed)),
          );
        }
        final data = snapshot.data!.data();
        final entries = data?['entries'] as List<dynamic>? ?? [];
        if (entries.isEmpty) {
          return Padding(
            padding: const EdgeInsets.only(bottom: kJamesStripClearance),
            child: Center(
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
            padding: const EdgeInsets.only(
                top: AppSpacing.sm, bottom: 100),
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

              final pctText = (_isLifetime &&
                      _totalPostboxes != null &&
                      _totalPostboxes! > 0)
                  ? ' (${(uniqueBoxes / _totalPostboxes! * 100).toStringAsFixed(1)}%)'
                  : '';
              final trailingText = _isLifetime
                  ? '$uniqueBoxes ${uniqueBoxes == 1 ? 'box' : 'boxes'}$pctText · $totalPoints pts'
                  : '$points pts';

              return Card(
                color: isCurrentUser
                    ? postalRed.withValues(alpha: 0.08)
                    : null,
                child: ListTile(
                  onTap: entryUid != null
                      ? () => Navigator.of(context).push(UserProfilePage.route(entryUid))
                      : null,
                  leading: _rankWidget(rank),
                  title: Text(
                    displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: isCurrentUser
                        ? const TextStyle(fontWeight: FontWeight.bold)
                        : null,
                  ),
                  trailing: Text(
                    trailingText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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

/// Leaderboard tab showing the current user alongside their friends,
/// ranked by the given period's score. Fetches scores from user documents
/// directly so all friends are visible regardless of global ranking.
class _FriendsPeriodList extends StatefulWidget {
  final String period;
  const _FriendsPeriodList({super.key, required this.period});

  @override
  State<_FriendsPeriodList> createState() => _FriendsPeriodListState();
}

class _FriendsPeriodListState extends State<_FriendsPeriodList> {
  final String? _currentUid = FirebaseAuth.instance.currentUser?.uid;

  int? _totalPostboxes;

  // Stream cached here so that setState (e.g. pull-to-refresh) doesn't
  // recreate the stream and cause StreamBuilder to flash a loading indicator.
  Stream<DocumentSnapshot<Map<String, dynamic>>>? _userStream;

  // Cached fetch future and the key values it was built from.
  // Set inside build() — safe because _scoreFuture is only consumed by
  // the FutureBuilder and never drives setState directly.
  Future<List<Map<String, dynamic>>>? _scoreFuture;
  Set<String> _lastFriendUids = const {};
  // Track the current user's own period scores so that the Friends
  // leaderboard auto-refreshes after the user claims a postbox.
  int _lastPeriodScore = -1;
  int _lastSecondaryScore = -1;

  @override
  void initState() {
    super.initState();
    if (_currentUid != null) {
      _userStream = FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUid)
          .snapshots();
    }
    _loadTotalPostboxes();
  }

  Future<void> _loadTotalPostboxes() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('meta')
          .doc('stats')
          .get();
      final total = (doc.data()?['totalPostboxes'] as num?)?.toInt();
      if (mounted && total != null && total > 0) {
        setState(() => _totalPostboxes = total);
      }
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> _fetchScores(Set<String> friendUids) async {
    final visibleUids = <String>{
      if (_currentUid != null) _currentUid!,
      ...friendUids,
    }.toList();

    const batchSize = 30;
    final allDocs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    for (var i = 0; i < visibleUids.length; i += batchSize) {
      final batch = visibleUids.sublist(
          i, (i + batchSize).clamp(0, visibleUids.length));
      try {
        final snap = await FirebaseFirestore.instance
            .collection('users')
            .where(FieldPath.documentId, whereIn: batch)
            .get();
        allDocs.addAll(snap.docs);
      } catch (_) {}
    }

    final isLifetime = widget.period == 'lifetime';
    final scoreField = switch (widget.period) {
      'daily' => 'dailyPoints',
      'weekly' => 'weeklyPoints',
      'monthly' => 'monthlyPoints',
      _ => 'uniquePostboxesClaimed', // lifetime
    };

    final entries = allDocs
        .where((d) => d.exists)
        .map((d) => <String, dynamic>{
              'uid': d.id,
              'displayName': d.data()['displayName'] as String? ?? 'Unknown',
              'score': (d.data()[scoreField] as num?)?.toInt() ?? 0,
              'uniquePostboxesClaimed':
                  (d.data()['uniquePostboxesClaimed'] as num?)?.toInt() ?? 0,
              'totalPoints':
                  (d.data()['lifetimePoints'] as num?)?.toInt() ?? 0,
            })
        .toList();

    if (isLifetime) {
      entries.sort((a, b) {
        final ua = a['uniquePostboxesClaimed'] as int;
        final ub = b['uniquePostboxesClaimed'] as int;
        if (ub != ua) return ub - ua;
        return (b['totalPoints'] as int) - (a['totalPoints'] as int);
      });
    } else {
      entries.sort((a, b) => (b['score'] as int) - (a['score'] as int));
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    if (_currentUid == null || _userStream == null) {
      return const Padding(
        padding: EdgeInsets.only(bottom: kJamesStripClearance),
        child: Center(child: CircularProgressIndicator(color: postalRed)),
      );
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _userStream,
      builder: (context, userSnap) {
        if (userSnap.hasError) {
          return Padding(
            padding: const EdgeInsets.only(bottom: kJamesStripClearance),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline,
                      size: 48,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(height: AppSpacing.md),
                  Text('Could not load friends',
                      style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
          );
        }
        if (!userSnap.hasData) {
          return const Padding(
            padding: EdgeInsets.only(bottom: kJamesStripClearance),
            child: Center(child: CircularProgressIndicator(color: postalRed)),
          );
        }

        final userData = userSnap.data!.data();
        final friendUids = (userData?['friends'] as List<dynamic>?)
                ?.whereType<String>()
                .toSet() ??
            <String>{};

        // Trigger a new fetch when the friends list changes OR when the
        // current user's own period scores change (e.g. after claiming).
        final scoreField = switch (widget.period) {
          'daily' => 'dailyPoints',
          'weekly' => 'weeklyPoints',
          'monthly' => 'monthlyPoints',
          _ => 'uniquePostboxesClaimed',
        };
        final myPeriodScore = (userData?[scoreField] as num?)?.toInt() ?? 0;
        final mySecondaryScore =
            (userData?['lifetimePoints'] as num?)?.toInt() ?? 0;
        final friendsChanged = !setEquals(_lastFriendUids, friendUids);
        final scoresChanged = myPeriodScore != _lastPeriodScore ||
            mySecondaryScore != _lastSecondaryScore;
        if (friendsChanged || scoresChanged) {
          _lastFriendUids = friendUids;
          _lastPeriodScore = myPeriodScore;
          _lastSecondaryScore = mySecondaryScore;
          _scoreFuture = _fetchScores(friendUids);
        }

        return FutureBuilder<List<Map<String, dynamic>>>(
          future: _scoreFuture,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting &&
                snap.data == null) {
              return const Padding(
                padding: EdgeInsets.only(bottom: kJamesStripClearance),
                child: Center(child: CircularProgressIndicator(color: postalRed)),
              );
            }
            if (snap.hasError) {
              return Padding(
                padding: const EdgeInsets.only(bottom: kJamesStripClearance),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline,
                          size: 48,
                          color: Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(height: AppSpacing.md),
                      Text('Could not load leaderboard',
                          style: Theme.of(context).textTheme.titleMedium),
                    ],
                  ),
                ),
              );
            }

            final entries = snap.data!;

            if (entries.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.group_outlined,
                          size: 48,
                          color: Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        'No scores yet',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        'Add friends from the Friends tab to see how you compare.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
              );
            }

            return RefreshIndicator(
              color: postalRed,
              onRefresh: () {
                setState(() {
                  _scoreFuture = _fetchScores(_lastFriendUids);
                });
                return _scoreFuture!;
              },
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(
                    top: AppSpacing.sm, bottom: 100),
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final e = entries[index];
                  final rank = index + 1;
                  final displayName = e['displayName'] as String? ?? 'Unknown';
                  final entryUid = e['uid'] as String?;
                  final isCurrentUser = entryUid != null && entryUid == _currentUid;
                  final isLifetime = widget.period == 'lifetime';

                  final String trailingText;
                  if (isLifetime) {
                    final uniqueBoxes = e['uniquePostboxesClaimed'] as int;
                    final totalPoints = e['totalPoints'] as int;
                    final pctText = (_totalPostboxes != null && _totalPostboxes! > 0)
                        ? ' (${(uniqueBoxes / _totalPostboxes! * 100).toStringAsFixed(1)}%)'
                        : '';
                    trailingText =
                        '$uniqueBoxes ${uniqueBoxes == 1 ? 'box' : 'boxes'}$pctText · $totalPoints pts';
                  } else {
                    final score = e['score'] as int;
                    trailingText = '$score pts';
                  }

                  return Card(
                    color: isCurrentUser ? postalRed.withValues(alpha: 0.08) : null,
                    child: ListTile(
                      onTap: entryUid != null
                          ? () => Navigator.of(context)
                              .push(UserProfilePage.route(entryUid))
                          : null,
                      leading: _friendsRankWidget(rank),
                      title: Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: isCurrentUser
                            ? const TextStyle(fontWeight: FontWeight.bold)
                            : null,
                      ),
                      trailing: Text(
                        trailingText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: isCurrentUser
                                  ? postalRed
                                  : Theme.of(context).colorScheme.onSurfaceVariant,
                              fontWeight:
                                  isCurrentUser ? FontWeight.bold : FontWeight.normal,
                            ),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  Widget _friendsRankWidget(int rank) {
    switch (rank) {
      case 1:
        return const Icon(Icons.emoji_events, color: postalGold, size: 32);
      case 2:
        return Icon(Icons.emoji_events,
            color: Colors.grey.shade400, size: 32);
      case 3:
        return Icon(Icons.emoji_events,
            color: Colors.brown.shade300, size: 32);
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
