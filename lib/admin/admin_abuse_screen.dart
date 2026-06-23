import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:postbox_game/firebase_functions_eu.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:postbox_game/admin/admin_access.dart';
import 'package:postbox_game/maintenance_guard.dart';
import 'package:postbox_game/theme.dart';
import 'package:url_launcher/url_launcher.dart';

/// In-app review queue for shadow-mode abuse-detection flags. Visible only to
/// users holding the `admin` custom claim (see [AdminAccess]). Flags are written
/// by the `onClaimCreated` Cloud Function; "Mark reviewed" calls `reviewFlag`.
/// Shadow mode: these flags have no user-facing effect — reviewing is triage
/// only (no claim is voided here).
class AdminAbuseScreen extends StatefulWidget {
  const AdminAbuseScreen({super.key});

  @override
  State<AdminAbuseScreen> createState() => _AdminAbuseScreenState();
}

class _AdminAbuseScreenState extends State<AdminAbuseScreen> {
  // Force a token refresh once on entry to pick up a freshly-granted admin
  // claim, then cache the result (mirrors AdminReportsScreen).
  late final Future<bool> _adminCheck = AdminAccess.isAdmin(forceRefresh: true);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _adminCheck,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator(color: postalRed)));
        }
        if (snap.data != true) {
          return Scaffold(
            appBar: AppBar(title: const Text('Abuse review')),
            body: const Center(child: Text('You do not have access to this area.')),
          );
        }
        return DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Abuse review'),
              bottom: const TabBar(tabs: [Tab(text: 'Open'), Tab(text: 'Reviewed')]),
            ),
            body: const TabBarView(
              children: [_FlagList(reviewed: false), _FlagList(reviewed: true)],
            ),
          ),
        );
      },
    );
  }
}

class _FlagList extends StatelessWidget {
  const _FlagList({required this.reviewed});
  final bool reviewed;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('moderationFlags')
          .where('reviewed', isEqualTo: reviewed)
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: postalRed));
        }
        if (snap.hasError) return Center(child: Text('Could not load flags: ${snap.error}'));
        final docs = (snap.data?.docs ?? []).toList()
          ..sort((a, b) {
            final ta = a.data()['createdAt'];
            final tb = b.data()['createdAt'];
            if (ta is Timestamp && tb is Timestamp) return tb.compareTo(ta);
            return 0;
          });
        if (docs.isEmpty) {
          return Center(child: Text(reviewed ? 'No reviewed flags' : 'No open flags'));
        }
        return ListView.separated(
          padding: const EdgeInsets.all(AppSpacing.md),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.md),
          itemBuilder: (_, i) => _FlagCard(id: docs[i].id, data: docs[i].data()),
        );
      },
    );
  }
}

class _FlagCard extends StatefulWidget {
  const _FlagCard({required this.id, required this.data});
  final String id;
  final Map<String, dynamic> data;

  @override
  State<_FlagCard> createState() => _FlagCardState();
}

class _FlagCardState extends State<_FlagCard> {
  bool _busy = false;

  Map<String, dynamic> get d => widget.data;
  bool get isReviewed => d['reviewed'] == true;
  double? get _lat => (d['lat'] as num?)?.toDouble();
  double? get _lng => (d['lng'] as num?)?.toDouble();

  static const _severityColors = {
    'low': Colors.amber,
    'med': Colors.orange,
    'high': Colors.redAccent,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final created = d['createdAt'];
    final when =
        created is Timestamp ? DateFormat.yMMMd().add_jm().format(created.toDate().toLocal()) : '';
    final reasons = (d['reasons'] as List?)?.cast<dynamic>().map((e) => '$e').toList() ?? const [];
    final severity = (d['severity'] as String?) ?? 'low';
    final uid = (d['uid'] as String?) ?? '?';
    final claimId = d['claimId'] as String?;
    final signals = (d['signals'] as Map?)?.cast<String, dynamic>() ?? const {};

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.gpp_maybe_outlined, color: postalRed),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text('Flag · ${uid.length > 8 ? '${uid.substring(0, 8)}…' : uid}',
                      style: theme.textTheme.titleMedium),
                ),
                Chip(
                  label: Text(severity.toUpperCase()),
                  backgroundColor:
                      (_severityColors[severity] ?? Colors.grey).withValues(alpha: 0.18),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            if (when.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(when, style: theme.textTheme.bodySmall),
              ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: 4,
              children: [
                for (final r in reasons)
                  Chip(
                    label: Text(_reasonLabel(r)),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            _InfoRow(
              icon: Icons.insights_outlined,
              child: Text(_signalSummary(signals)),
            ),
            if (claimId != null)
              _InfoRow(icon: Icons.receipt_long_outlined, child: Text('Claim: $claimId')),
            if (_lat != null && _lng != null)
              _InfoRow(
                icon: Icons.place_outlined,
                child: Row(
                  children: [
                    Expanded(child: Text('${_lat!.toStringAsFixed(6)}, ${_lng!.toStringAsFixed(6)}')),
                    TextButton.icon(
                      onPressed: () => _openMap(_lat!, _lng!),
                      icon: const Icon(Icons.map_outlined, size: 18),
                      label: const Text('Map'),
                    ),
                  ],
                ),
              ),
            if (!isReviewed) ...[
              const SizedBox(height: AppSpacing.sm),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton(
                    onPressed: _busy ? null : _markReviewed,
                    child: const Text('Mark reviewed'),
                  ),
                ],
              ),
            ],
            if (isReviewed && (d['reviewNote'] as String?)?.isNotEmpty == true)
              _InfoRow(icon: Icons.notes, child: Text(d['reviewNote'] as String)),
          ],
        ),
      ),
    );
  }

  String _reasonLabel(String key) {
    switch (key) {
      case 'impossible_travel':
        return 'Impossible travel';
      case 'out_of_window':
        return 'Out of window';
      case 'coord_cluster':
        return 'Coordinate cluster';
      default:
        return key;
    }
  }

  String _signalSummary(Map<String, dynamic> s) {
    final speed = (s['travelSpeedMPerMin'] as num?)?.toDouble();
    final skew = (s['clockSkewMs'] as num?)?.toInt();
    final repeat = (s['coordRepeatCount'] as num?)?.toInt();
    final parts = <String>[];
    if (speed != null) parts.add('${speed.toStringAsFixed(0)} m/min');
    if (skew != null) parts.add('skew ${(skew / 1000).toStringAsFixed(0)} s');
    if (repeat != null) parts.add('×$repeat same spot');
    return parts.isEmpty ? 'no signal values' : parts.join('  ·  ');
  }

  Future<void> _openMap(double lat, double lng) async {
    final uri = Uri.parse('https://www.openstreetmap.org/?mlat=$lat&mlon=$lng#map=19/$lat/$lng');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open the map')));
    }
  }

  Future<void> _markReviewed() async {
    if (MaintenanceGuard.blocked(context, actionLabel: 'review flags')) return;
    setState(() => _busy = true);
    try {
      await appFunctions.httpsCallable('reviewFlag').call(<String, dynamic>{'flagId': widget.id});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Flag marked reviewed')));
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: ${e.message ?? e.code}')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Failed. Please try again.')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.child});
  final IconData icon;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: DefaultTextStyle.merge(
                style: Theme.of(context).textTheme.bodyMedium, child: child),
          ),
        ],
      ),
    );
  }
}
