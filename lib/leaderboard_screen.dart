import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Leaderboard with Daily, Weekly, Monthly tabs.
/// Reads from Firestore leaderboards/{period}; backend can aggregate via Cloud Function.
class LeaderboardScreen extends StatelessWidget {
  const LeaderboardScreen({Key? key}) : super(key: key);

  static const List<String> _periods = ['daily', 'weekly', 'monthly'];

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _periods.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Leaderboard'),
          bottom: TabBar(
            tabs: _periods
                .map((p) => Tab(text: p[0].toUpperCase() + p.substring(1)))
                .toList(),
          ),
        ),
        body: TabBarView(
          children: _periods
              .map((period) => _LeaderboardList(period: period))
              .toList(),
        ),
      ),
    );
  }
}

class _LeaderboardList extends StatelessWidget {
  final String period;

  const _LeaderboardList({Key? key, required this.period}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseFirestore.instance
        .collection('leaderboards')
        .doc(period)
        .snapshots();

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: ref,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snapshot.data!.data();
        final entries = data?['entries'] as List<dynamic>? ?? [];
        if (entries.isEmpty) {
          return const Center(
            child: Text(
              'No rankings yet. Leaderboard is updated by the backend.',
              textAlign: TextAlign.center,
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final e = entries[index] as Map<String, dynamic>? ?? {};
            final rank = index + 1;
            final displayName = e['displayName'] as String? ?? 'Unknown';
            final points = (e['points'] is num) ? (e['points'] as num).toInt() : 0;
            return Card(
              child: ListTile(
                leading: CircleAvatar(
                  child: Text('$rank'),
                ),
                title: Text(displayName),
                trailing: Text('$points pts'),
              ),
            );
          },
        );
      },
    );
  }
}
