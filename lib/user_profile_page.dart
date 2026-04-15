import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
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
    final results = await Future.wait<DocumentSnapshot<Map<String, dynamic>>>([
      db.collection('users').doc(widget.uid).get(),
      db.collection('leaderboards').doc('daily').get(),
      db.collection('leaderboards').doc('weekly').get(),
      db.collection('leaderboards').doc('monthly').get(),
      db.collection('leaderboards').doc('lifetime').get(),
    ]);

    final userSnap = results[0];
    final userData = userSnap.data() ?? {};

    final periods = ['daily', 'weekly', 'monthly', 'lifetime'];
    final Map<String, int?> ranks = {};
    for (var i = 0; i < periods.length; i++) {
      final lbSnap = results[i + 1];
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

    return _ProfileData(
      displayName: userData['displayName'] as String? ?? 'Unknown',
      createdAt: (userData['createdAt'] as Timestamp?)?.toDate(),
      streak: (userData['streak'] as num?)?.toInt() ?? 0,
      uniqueBoxes: (userData['uniquePostboxesClaimed'] as num?)?.toInt() ?? 0,
      lifetimePoints: (userData['lifetimePoints'] as num?)?.toInt() ?? 0,
      ranks: ranks,
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

class _ProfileData {
  final String displayName;
  final DateTime? createdAt;
  final int streak;
  final int uniqueBoxes;
  final int lifetimePoints;
  final Map<String, int?> ranks;

  const _ProfileData({
    required this.displayName,
    required this.createdAt,
    required this.streak,
    required this.uniqueBoxes,
    required this.lifetimePoints,
    required this.ranks,
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
    final parts = name.split(' ');
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
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _StatCell(
                    value: '${data.uniqueBoxes}',
                    label: 'Unique boxes',
                    color: postalGold),
                const VerticalDivider(),
                _StatCell(
                    value: '${data.lifetimePoints}',
                    label: 'Lifetime pts',
                    color: postalRed),
                const VerticalDivider(),
                _StatCell(
                    value: '🔥 ${data.streak}',
                    label: 'Day streak',
                    color: Colors.green),
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
