import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:postbox_game/london_date.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/wear/wear_round_inset.dart';
import 'package:postbox_game/wear/wear_theme.dart';

/// The periods the watch board cycles through.
///
/// Lifetime is deliberately excluded: `leaderboards/lifetime` stores a
/// different entry shape (`uniquePostboxesClaimed` / `totalPoints`) with a
/// different sort, and supporting it would double this page's parsing for a
/// view nobody checks mid-walk.
const List<String> kWearLeaderboardPeriods = <String>[
  'daily',
  'weekly',
  'monthly',
];

/// Short enough to sit on one line of the inscribed square.
String wearPeriodLabel(String period) {
  switch (period) {
    case 'weekly':
      return 'This week';
    case 'monthly':
      return 'This month';
    default:
      return 'Today';
  }
}

/// One row of the watch leaderboard.
class WearLeaderboardEntry {
  const WearLeaderboardEntry({
    required this.rank,
    required this.displayName,
    required this.points,
    required this.isMe,
  });

  final int rank;
  final String displayName;
  final int points;
  final bool isMe;
}

/// Top three plus your own standing, at a glance.
///
/// Reads `leaderboards/{period}` directly — the documents are world-readable to
/// signed-in users (`firestore.rules`) and the backend already writes them
/// sorted, so there is no client-side aggregation and no callable round-trip.
///
/// Signed-out users never reach this page: the rules require auth, so the shell
/// leaves it out of the page list entirely rather than showing a dead end.
class WearLeaderboardPage extends StatefulWidget {
  const WearLeaderboardPage({
    super.key,
    FirebaseFirestore? firestore,
    String? uid,
  })  : _firestore = firestore,
        _uid = uid;

  final FirebaseFirestore? _firestore;
  final String? _uid;

  @override
  State<WearLeaderboardPage> createState() => _WearLeaderboardPageState();
}

class _WearLeaderboardPageState extends State<WearLeaderboardPage> {
  late final FirebaseFirestore _firestore =
      widget._firestore ?? FirebaseFirestore.instance;
  late final String? _uid =
      widget._uid ?? FirebaseAuth.instance.currentUser?.uid;

  int _periodIndex = 0;
  late Stream<DocumentSnapshot<Map<String, dynamic>>> _stream = _streamFor(
    kWearLeaderboardPeriods[0],
  );

  String get _period => kWearLeaderboardPeriods[_periodIndex];

  Stream<DocumentSnapshot<Map<String, dynamic>>> _streamFor(String period) =>
      _firestore.collection('leaderboards').doc(period).snapshots();

  void _cyclePeriod() {
    setState(() {
      _periodIndex = (_periodIndex + 1) % kWearLeaderboardPeriods.length;
      _stream = _streamFor(_period);
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snapshot) {
        if (!snapshot.hasData && !snapshot.hasError) {
          return WearLeaderboardView(
            period: _period,
            entries: null,
            onCyclePeriod: _cyclePeriod,
          );
        }
        return WearLeaderboardView(
          period: _period,
          entries: parseWearLeaderboard(
            data: snapshot.data?.data(),
            period: _period,
            today: todayLondon(),
            myUid: _uid,
          ),
          fromCache: snapshot.data?.metadata.isFromCache ?? false,
          onCyclePeriod: _cyclePeriod,
        );
      },
    );
  }
}

/// Pure parse of a `leaderboards/{period}` document into ranked rows.
///
/// Discards every entry when the stored `periodKey` is stale — the same guard
/// the phone applies in `leaderboard_screen.dart`. Without it the watch would
/// keep showing yesterday's board after midnight until the first claim of the
/// day triggers the server-side reset, which is exactly the window a player
/// checks their wrist.
List<WearLeaderboardEntry> parseWearLeaderboard({
  required Map<String, dynamic>? data,
  required String period,
  required String today,
  String? myUid,
}) {
  final storedPeriodKey = data?['periodKey'] as String?;
  final expectedKey = expectedPeriodKey(period, today);
  final keyMatches = expectedKey == null || storedPeriodKey == expectedKey;
  if (!keyMatches) return const <WearLeaderboardEntry>[];

  final raw = data?['entries'] as List<dynamic>? ?? const <dynamic>[];
  final result = <WearLeaderboardEntry>[];
  for (var i = 0; i < raw.length; i++) {
    final e = raw[i];
    if (e is! Map) continue;
    final uid = e['uid'] as String?;
    result.add(WearLeaderboardEntry(
      rank: i + 1,
      displayName: e['displayName'] as String? ?? 'Unknown',
      points: (e['points'] is num) ? (e['points'] as num).toInt() : 0,
      isMe: myUid != null && uid == myUid,
    ));
  }
  return result;
}

/// Pure, prop-driven rendering for [WearLeaderboardPage].
///
/// A null [entries] means "still loading"; an empty list means "no scores".
class WearLeaderboardView extends StatelessWidget {
  const WearLeaderboardView({
    super.key,
    required this.period,
    required this.entries,
    required this.onCyclePeriod,
    this.fromCache = false,
  });

  final String period;
  final List<WearLeaderboardEntry>? entries;
  final VoidCallback onCyclePeriod;

  /// Firestore served this from its offline cache. The phone shows a
  /// `StaleDataChip`; there is no room for one here, so the title is muted
  /// instead.
  final bool fromCache;

  /// How many rows fit above the "you" row inside the inscribed square.
  static const int visibleRows = 3;

  @override
  Widget build(BuildContext context) {
    final list = entries;
    return Container(
      color: Colors.black,
      child: WearRoundInset(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              _title(context),
              const SizedBox(height: WearSpacing.sm),
              if (list == null)
                const CircularProgressIndicator(strokeWidth: 2)
              else if (list.isEmpty)
                Text(
                  'No scores yet',
                  style: Theme.of(context).textTheme.bodyMedium,
                )
              else
                ..._rows(context, list),
            ],
          ),
        ),
      ),
    );
  }

  Widget _title(BuildContext context) {
    final style = Theme.of(context).textTheme.titleSmall?.copyWith(
          color: fromCache ? Colors.white.withValues(alpha: 0.5) : null,
        );
    return GestureDetector(
      onTap: onCyclePeriod,
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(wearPeriodLabel(period), style: style),
          const SizedBox(width: 2),
          // Signals that the title cycles daily -> weekly -> monthly. The
          // rotary crown can't be used for this: it is already bound to paging.
          Icon(
            Icons.unfold_more,
            size: 12,
            color: Colors.white.withValues(alpha: 0.6),
          ),
        ],
      ),
    );
  }

  List<Widget> _rows(BuildContext context, List<WearLeaderboardEntry> list) {
    final rows = <Widget>[];
    final top = list.take(visibleRows).toList();
    for (var i = 0; i < top.length; i++) {
      if (i > 0) rows.add(const SizedBox(height: WearSpacing.xs));
      rows.add(_entryRow(context, top[i]));
    }

    // Your own standing, but only when it isn't already on screen.
    final me = list.where((e) => e.isMe).toList();
    if (me.isNotEmpty && me.first.rank > visibleRows) {
      rows.add(const SizedBox(height: WearSpacing.sm));
      rows.add(_entryRow(context, me.first));
    }
    return rows;
  }

  Widget _entryRow(BuildContext context, WearLeaderboardEntry entry) {
    final base = Theme.of(context).textTheme.bodySmall;
    final style = entry.isMe
        ? base?.copyWith(color: postalGold, fontWeight: FontWeight.bold)
        : base;
    return Row(
      children: [
        SizedBox(
          width: 16,
          child: Text(
            '${entry.rank}',
            style: style,
            textAlign: TextAlign.right,
          ),
        ),
        const SizedBox(width: WearSpacing.sm),
        Expanded(
          child: Text(
            entry.isMe ? 'You' : entry.displayName,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: WearSpacing.sm),
        Text('${entry.points}', style: style),
      ],
    );
  }
}
