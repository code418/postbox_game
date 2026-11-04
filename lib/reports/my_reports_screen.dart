import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/theme.dart';

/// Lists the reports the signed-in user has submitted, with their current
/// review status. Reachable from the app bar overflow menu.
class MyReportsScreen extends StatelessWidget {
  const MyReportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return Scaffold(
      appBar: AppBar(title: const Text('My reports')),
      body: uid == null
          ? const Center(child: Text('Not signed in'))
          : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('reports')
                  .where('reporterUid', isEqualTo: uid)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator(color: postalRed));
                }
                if (snap.hasError) {
                  return const Center(child: Text('Could not load your reports'));
                }
                final docs = (snap.data?.docs ?? []).toList()
                  ..sort((a, b) {
                    final ta = a.data()['createdAt'];
                    final tb = b.data()['createdAt'];
                    if (ta is Timestamp && tb is Timestamp) return tb.compareTo(ta);
                    return 0;
                  });
                if (docs.isEmpty) {
                  return const _Empty();
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (_, i) => _ReportCard(data: docs[i].data()),
                );
              },
            ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.flag_outlined, size: 64, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.2)),
            const SizedBox(height: AppSpacing.md),
            const Text('No reports yet'),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Spot a missing postbox or a wrong cypher? Report it from the Claim or History screens.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.data});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final type = data['type'] as String?;
    final status = (data['status'] as String?) ?? 'pending';
    final created = data['createdAt'];
    final when = created is Timestamp ? DateFormat.yMMMd().add_jm().format(created.toDate().toLocal()) : '';
    final isMissing = type == 'missing_postbox';
    String? suggestedLabel;
    if (data.containsKey('suggestedMonarch')) {
      final s = data['suggestedMonarch'];
      suggestedLabel = s == null ? 'plain (no cypher)' : (MonarchInfo.labels[s as String] ?? s);
    }
    return Card(
      child: ListTile(
        leading: Icon(isMissing ? Icons.add_location_alt_outlined : Icons.flag_outlined, color: postalRed),
        title: Text(isMissing ? 'Missing postbox' : 'Wrong cypher'),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (suggestedLabel != null) Text('Suggested cypher: $suggestedLabel'),
            if (when.isNotEmpty) Text(when, style: Theme.of(context).textTheme.bodySmall),
            if ((data['reviewNote'] as String?)?.isNotEmpty ?? false)
              Text('Reviewer: ${data['reviewNote']}', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        trailing: _StatusChip(status: status),
        isThreeLine: true,
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final String status;
  @override
  Widget build(BuildContext context) {
    final (Color c, String label) = switch (status) {
      'accepted' => (Colors.green, 'Accepted'),
      'rejected' => (Colors.redAccent, 'Rejected'),
      _ => (Colors.orange, 'Pending'),
    };
    return Chip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      backgroundColor: c.withValues(alpha: 0.15),
      side: BorderSide(color: c.withValues(alpha: 0.4)),
      visualDensity: VisualDensity.compact,
    );
  }
}
