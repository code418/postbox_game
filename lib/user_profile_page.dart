import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:postbox_game/london_date.dart';
import 'package:postbox_game/streak_service.dart' show freshStreak;
import 'package:postbox_game/theme.dart';

class UserProfilePage extends StatefulWidget {
  final String uid;

  const UserProfilePage({super.key, required this.uid});

  static Route<void> route(String uid) =>
      MaterialPageRoute(builder: (_) => UserProfilePage(uid: uid));

  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  late final Future<_ProfileData> _profileFuture;

  @override
  void initState() {
    super.initState();
    _profileFuture = _load();
  }

  Future<_ProfileData> _load() async {
    final db = FirebaseFirestore.instance;
    final results = await Future.wait<dynamic>([
      db.collection('users').doc(widget.uid).get(),
      db.collection('leaderboards').doc('daily').get(),
      db.collection('leaderboards').doc('weekly').get(),
      db.collection('leaderboards').doc('monthly').get(),
      db.collection('leaderboards').doc('lifetime').get(),
      // Top 5 counties by totalPoints (descending). Capped low to keep the
      // section to a glanceable handful of rows; the full list isn't useful
      // on a profile page.
      db
          .collection('users')
          .doc(widget.uid)
          .collection('countyStats')
          .orderBy('totalPoints', descending: true)
          .limit(_kProfileCountyLimit)
          .get(),
    ]);

    final userSnap = results[0] as DocumentSnapshot<Map<String, dynamic>>;
    final userData = userSnap.data() ?? {};

    final periods = ['daily', 'weekly', 'monthly', 'lifetime'];
    final today = todayLondon();
    final Map<String, int?> ranks = {};
    for (var i = 0; i < periods.length; i++) {
      final lbSnap = results[i + 1] as DocumentSnapshot<Map<String, dynamic>>;
      // Skip stale leaderboards (periodKey mismatch) so a delayed or failed
      // newDayScoreboard doesn't surface yesterday's rankings as today's.
      final storedPeriodKey = lbSnap.data()?['periodKey'] as String?;
      final expectedKey = expectedPeriodKey(periods[i], today);
      if (expectedKey != null && storedPeriodKey != expectedKey) {
        ranks[periods[i]] = null;
        continue;
      }
      final entries = lbSnap.data()?['entries'] as List<dynamic>? ?? [];
      int? rank;
      for (var j = 0; j < entries.length; j++) {
        final e = entries[j];
        if (e is Map && e['uid'] == widget.uid) {
          rank = j + 1;
          break;
        }
      }
      ranks[periods[i]] = rank;
    }

    // ── County rankings ─────────────────────────────────────────────────────
    // For each county the user has stats in, fetch the per-county lifetime
    // leaderboard and find their rank. Done in parallel; missing leaderboard
    // doc → null rank (treated the same as outside top 100).
    final countyStatsSnap = results[5] as QuerySnapshot<Map<String, dynamic>>;
    final List<_CountyRanking> countyRankings = [];
    if (countyStatsSnap.docs.isNotEmpty) {
      final lbDocs = await Future.wait(countyStatsSnap.docs.map(
        (d) => db
            .collection('leaderboards')
            .doc('lifetime_by_county')
            .collection('counties')
            .doc(d.id)
            .get(),
      ));
      for (var i = 0; i < countyStatsSnap.docs.length; i++) {
        final stats = countyStatsSnap.docs[i].data();
        final lb = lbDocs[i].data();
        final entries = (lb?['entries'] as List<dynamic>?) ?? const [];
        int? rank;
        for (var j = 0; j < entries.length; j++) {
          final e = entries[j];
          if (e is Map && e['uid'] == widget.uid) {
            rank = j + 1;
            break;
          }
        }
        countyRankings.add(_CountyRanking(
          county: (stats['county'] as String?) ?? countyStatsSnap.docs[i].id,
          uniqueBoxes: (stats['uniquePostboxesClaimed'] as num?)?.toInt() ?? 0,
          totalPoints: (stats['totalPoints'] as num?)?.toInt() ?? 0,
          rank: rank,
        ));
      }
    }

    // Staleness check: the stored `streak` is only reset server-side on the
    // user's next claim, so a profile viewed after a broken streak would
    // otherwise show the old value until that happens. Shared with
    // StreakService and HomeWidgetService via the freshStreak helper.
    final streak = freshStreak(
          storedStreak: (userData['streak'] as num?)?.toInt(),
          lastClaimDate: userData['lastClaimDate'] as String?,
          today: today,
          yesterday: yesterdayLondon(),
        ) ??
        0;

    return _ProfileData(
      displayName: userData['displayName'] as String? ?? 'Unknown',
      createdAt: (userData['createdAt'] as Timestamp?)?.toDate(),
      streak: streak,
      uniqueBoxes: (userData['uniquePostboxesClaimed'] as num?)?.toInt() ?? 0,
      lifetimePoints: (userData['lifetimePoints'] as num?)?.toInt() ?? 0,
      maxDailyPoints: (userData['maxDailyPoints'] as num?)?.toInt() ?? 0,
      ranks: ranks,
      countyRankings: countyRankings,
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    final isOwn = currentUid == widget.uid;

    return Scaffold(
      appBar: AppBar(title: Text(isOwn ? 'Your Profile' : 'Player Profile')),
      body: FutureBuilder<_ProfileData>(
        future: _profileFuture,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.only(bottom: kJamesStripClearance),
              child: Center(child: CircularProgressIndicator(color: postalRed)),
            );
          }
          if (snap.hasError || snap.data == null) {
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
                    Text('Could not load profile',
                        style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
              ),
            );
          }
          return _ProfileBody(data: snap.data!);
        },
      ),
    );
  }
}

/// Number of counties listed under the profile page's "County rankings"
/// section. Profile is a glance view, not the full per-county leaderboard.
const int _kProfileCountyLimit = 5;

class _ProfileData {
  final String displayName;
  final DateTime? createdAt;
  final int streak;
  final int uniqueBoxes;
  final int lifetimePoints;
  final int maxDailyPoints;
  final Map<String, int?> ranks;
  final List<_CountyRanking> countyRankings;

  const _ProfileData({
    required this.displayName,
    required this.createdAt,
    required this.streak,
    required this.uniqueBoxes,
    required this.lifetimePoints,
    required this.maxDailyPoints,
    required this.ranks,
    required this.countyRankings,
  });
}

class _CountyRanking {
  final String county;
  final int uniqueBoxes;
  final int totalPoints;
  final int? rank;
  const _CountyRanking({
    required this.county,
    required this.uniqueBoxes,
    required this.totalPoints,
    required this.rank,
  });
}

class _ProfileBody extends StatelessWidget {
  final _ProfileData data;

  const _ProfileBody({required this.data});

  String _joinedText() {
    if (data.createdAt == null) return '';
    return 'Joined ${DateFormat('MMMM yyyy').format(data.createdAt!)}';
  }

  String _initials() {
    final name = data.displayName.trim();
    if (name.isEmpty) return '?';
    final parts = name.split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.substring(0, name.length.clamp(0, 2)).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        // ── Header ──────────────────────────────────────────────────────────
        Row(
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: postalRed,
              child: Text(
                _initials(),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(data.displayName,
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis),
                  if (data.createdAt != null)
                    Text(
                      _joinedText(),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),

        // ── Headline stats ───────────────────────────────────────────────────
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(
                vertical: AppSpacing.md, horizontal: AppSpacing.sm),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Expanded(
                      child: _StatCell(
                          value: '${data.uniqueBoxes}',
                          label: 'Unique boxes',
                          color: postalGold),
                    ),
                    Expanded(
                      child: _StatCell(
                          value: '${data.lifetimePoints}',
                          label: 'Lifetime pts',
                          color: postalRed),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Expanded(
                      child: _StatCell(
                          value: '🔥 ${data.streak}',
                          label: 'Day streak',
                          color: Colors.green),
                    ),
                    Expanded(
                      child: _StatCell(
                          value: '${data.maxDailyPoints}',
                          label: 'Best day',
                          color: Theme.of(context).colorScheme.primary),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),

        // ── Rankings ─────────────────────────────────────────────────────────
        Text(
          'CURRENT RANKINGS',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                letterSpacing: 0.8,
              ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Card(
          child: Column(
            children: [
              for (final period in ['daily', 'weekly', 'monthly', 'lifetime'])
                _RankRow(
                  period: period,
                  rank: data.ranks[period],
                  isLast: period == 'lifetime',
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Rankings shown for top 100 players per period',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context)
                    .colorScheme
                    .onSurfaceVariant
                    .withValues(alpha: 0.6),
              ),
        ),

        // ── County rankings ─────────────────────────────────────────────────
        if (data.countyRankings.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          Text(
            'COUNTY RANKINGS',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  letterSpacing: 0.8,
                ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Card(
            child: Column(
              children: [
                for (var i = 0; i < data.countyRankings.length; i++)
                  _CountyRankRow(
                    entry: data.countyRankings[i],
                    isLast: i == data.countyRankings.length - 1,
                  ),
              ],
            ),
          ),
        ],

        const SizedBox(height: kJamesStripClearance),
      ],
    );
  }
}

class _StatCell extends StatelessWidget {
  final String value;
  final String label;
  final Color color;

  const _StatCell(
      {required this.value, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 2),
        Text(label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                )),
      ],
    );
  }
}

class _CountyRankRow extends StatelessWidget {
  final _CountyRanking entry;
  final bool isLast;

  const _CountyRankRow({required this.entry, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final isFirst = entry.rank == 1;
    final boxesLabel = entry.uniqueBoxes == 1 ? 'box' : 'boxes';
    return Column(
      children: [
        ListTile(
          dense: true,
          title: Text(entry.county,
              style: Theme.of(context).textTheme.bodyMedium),
          subtitle: Text(
            '${entry.uniqueBoxes} $boxesLabel · ${entry.totalPoints} pts',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          trailing: entry.rank != null
              ? Text(
                  '#${entry.rank}${isFirst ? ' 🏆' : ''}',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: isFirst ? postalGold : null,
                      ),
                )
              : Text(
                  'Unranked',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontStyle: FontStyle.italic,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant
                            .withValues(alpha: 0.5),
                      ),
                ),
        ),
        if (!isLast) const Divider(height: 1, indent: 16, endIndent: 16),
      ],
    );
  }
}

class _RankRow extends StatelessWidget {
  final String period;
  final int? rank;
  final bool isLast;

  const _RankRow(
      {required this.period, required this.rank, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final label = period[0].toUpperCase() + period.substring(1);
    final isFirst = rank == 1;
    return Column(
      children: [
        ListTile(
          dense: true,
          title: Text(label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  )),
          trailing: rank != null
              ? Text(
                  '#$rank${isFirst ? ' 🏆' : ''}',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: isFirst ? postalGold : null,
                      ),
                )
              : Text(
                  'Unranked',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontStyle: FontStyle.italic,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant
                            .withValues(alpha: 0.5),
                      ),
                ),
        ),
        if (!isLast) const Divider(height: 1, indent: 16, endIndent: 16),
      ],
    );
  }
}
