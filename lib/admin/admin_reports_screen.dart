import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:postbox_game/admin/admin_access.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/reports/report_form_widgets.dart';
import 'package:postbox_game/reports/report_repository.dart' show plainCypher;
import 'package:postbox_game/theme.dart';
import 'package:url_launcher/url_launcher.dart';

/// In-app review queue for postbox-data problem reports. Visible only to users
/// holding the `admin` custom claim (see [AdminAccess]). Accepting a report
/// calls the `reviewReport` Cloud Function, which updates the Firestore postbox
/// entry, re-scores affected claims, and generates an osmChange file.
class AdminReportsScreen extends StatelessWidget {
  const AdminReportsScreen({super.key});

  static const _statuses = ['pending', 'accepted', 'rejected'];
  static const _labels = {'pending': 'Pending', 'accepted': 'Accepted', 'rejected': 'Rejected'};

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: AdminAccess.isAdmin(forceRefresh: true),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator(color: postalRed)));
        }
        if (snap.data != true) {
          return Scaffold(
            appBar: AppBar(title: const Text('Report review')),
            body: const Center(child: Text('You do not have access to this area.')),
          );
        }
        return DefaultTabController(
          length: _statuses.length,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Report review'),
              bottom: TabBar(tabs: [for (final s in _statuses) Tab(text: _labels[s])]),
            ),
            body: TabBarView(children: [for (final s in _statuses) _ReportList(status: s)]),
          ),
        );
      },
    );
  }
}

class _ReportList extends StatelessWidget {
  const _ReportList({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('reports').where('status', isEqualTo: status).snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(color: postalRed));
        }
        if (snap.hasError) return Center(child: Text('Could not load reports: ${snap.error}'));
        final docs = (snap.data?.docs ?? []).toList()
          ..sort((a, b) {
            final ta = a.data()['createdAt'];
            final tb = b.data()['createdAt'];
            if (ta is Timestamp && tb is Timestamp) return tb.compareTo(ta);
            return 0;
          });
        if (docs.isEmpty) return Center(child: Text('No $status reports'));
        return ListView.separated(
          padding: const EdgeInsets.all(AppSpacing.md),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.md),
          itemBuilder: (_, i) => _ReportCard(id: docs[i].id, data: docs[i].data()),
        );
      },
    );
  }
}

class _ReportCard extends StatefulWidget {
  const _ReportCard({required this.id, required this.data});
  final String id;
  final Map<String, dynamic> data;

  @override
  State<_ReportCard> createState() => _ReportCardState();
}

class _ReportCardState extends State<_ReportCard> {
  bool _busy = false;

  Map<String, dynamic> get d => widget.data;
  bool get isMissing => d['type'] == 'missing_postbox';
  bool get isPending => (d['status'] as String?) == 'pending';

  double? get _lat => (d['lat'] as num?)?.toDouble();
  double? get _lng => (d['lng'] as num?)?.toDouble();

  String _monarchLabel(Object? key) =>
      key == null ? 'plain (no cypher)' : (MonarchInfo.labels[key as String] ?? key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final created = d['createdAt'];
    final when = created is Timestamp ? DateFormat.yMMMd().add_jm().format(created.toDate().toLocal()) : '';
    final note = d['note'] as String?;
    final photos = (d['photos'] as List?)?.cast<dynamic>() ?? const [];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(isMissing ? Icons.add_location_alt_outlined : Icons.flag_outlined, color: postalRed),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(isMissing ? 'Missing postbox' : 'Wrong cypher', style: theme.textTheme.titleMedium)),
                if (when.isNotEmpty) Text(when, style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (isMissing && _lat != null && _lng != null)
              _InfoRow(
                icon: Icons.place_outlined,
                child: Row(
                  children: [
                    Expanded(child: Text('${_lat!.toStringAsFixed(6)}, ${_lng!.toStringAsFixed(6)}'
                        '${d['accuracyMeters'] is num ? '  ·  ±${(d['accuracyMeters'] as num).round()} m' : ''}')),
                    TextButton.icon(
                      onPressed: () => _openMap(_lat!, _lng!),
                      icon: const Icon(Icons.map_outlined, size: 18),
                      label: const Text('Map'),
                    ),
                  ],
                ),
              ),
            if (!isMissing)
              _InfoRow(
                icon: Icons.markunread_mailbox_outlined,
                child: Text('Recorded: ${_monarchLabel(d['currentMonarch'])}'
                    '${d['postboxId'] != null ? '   ·   ${d['postboxId']}' : ''}'),
              ),
            if (d.containsKey('suggestedMonarch'))
              _InfoRow(icon: Icons.lightbulb_outline, child: Text('Suggested: ${_monarchLabel(d['suggestedMonarch'])}')),
            if ((d['suggestedReference'] as String?)?.isNotEmpty ?? false)
              _InfoRow(icon: Icons.tag, child: Text('Suggested ref: ${d['suggestedReference']}')),
            if (note != null && note.isNotEmpty)
              _InfoRow(icon: Icons.notes, child: Text(note)),
            if (photos.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              SizedBox(
                height: 84,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [for (final p in photos) _PhotoThumb(photo: Map<String, dynamic>.from(p as Map))],
                ),
              ),
            ],
            if (!isPending) ...[
              const SizedBox(height: AppSpacing.sm),
              _ReviewOutcome(data: d),
            ],
            if (isPending) ...[
              const SizedBox(height: AppSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: _busy ? null : _reject, child: const Text('Reject')),
                  const SizedBox(width: AppSpacing.sm),
                  FilledButton(onPressed: _busy ? null : _accept, child: const Text('Accept')),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _openMap(double lat, double lng) async {
    final uri = Uri.parse('https://www.openstreetmap.org/?mlat=$lat&mlon=$lng#map=19/$lat/$lng');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open the map')));
    }
  }

  Future<void> _reject() async {
    final noteController = TextEditingController();
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Reject report'),
          content: TextField(
            controller: noteController,
            maxLength: 280,
            decoration: const InputDecoration(labelText: 'Reason (optional, shown to the reporter)'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reject')),
          ],
        ),
      );
      if (ok != true) return;
      await _call({
        'reportId': widget.id,
        'decision': 'reject',
        if (noteController.text.trim().isNotEmpty) 'reviewNote': noteController.text.trim(),
      });
    } finally {
      noteController.dispose();
    }
  }

  Future<void> _accept() async {
    // Default the final-cypher picker to the suggestion (if any).
    String initialCypher = notSureCypher;
    if (d.containsKey('suggestedMonarch')) {
      final s = d['suggestedMonarch'];
      initialCypher = s == null ? plainCypher : s as String;
    } else if (d['currentMonarch'] is String) {
      initialCypher = d['currentMonarch'] as String;
    }
    final result = await showDialog<_AcceptResult>(
      context: context,
      builder: (ctx) => _AcceptDialog(isCypherReport: !isMissing, initialCypher: initialCypher),
    );
    if (result == null) return;
    final payload = <String, dynamic>{
      'reportId': widget.id,
      'decision': 'accept',
      if (result.reviewNote != null && result.reviewNote!.isNotEmpty) 'reviewNote': result.reviewNote,
      if (result.reference != null && result.reference!.isNotEmpty) 'finalReference': result.reference,
    };
    // finalMonarch: omit = "use the report's suggestion / leave unset";
    // null = plain; a key = that cypher.
    if (result.cypher != notSureCypher) {
      payload['finalMonarch'] = result.cypher == plainCypher ? null : result.cypher;
    }
    await _call(payload, isAccept: true);
  }

  Future<void> _call(Map<String, dynamic> payload, {bool isAccept = false}) async {
    setState(() => _busy = true);
    try {
      final res = await FirebaseFunctions.instance.httpsCallable('reviewReport').call(payload);
      if (!mounted) return;
      if (isAccept) {
        final m = Map<String, dynamic>.from(res.data as Map);
        await _showAcceptedDialog(m);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report rejected')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showAcceptedDialog(Map<String, dynamic> m) {
    final editUrl = m['osmEditUrl'] as String?;
    final oscPath = m['osmChangesetPath'] as String?;
    final rescored = (m['rescoredClaims'] as num?)?.toInt() ?? 0;
    final users = (m['affectedUsers'] as num?)?.toInt() ?? 0;
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.check_circle_outline, color: postalRed, size: 36),
        title: const Text('Report accepted'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('The Firestore postbox entry was updated.'),
            if (rescored > 0) ...[
              const SizedBox(height: 8),
              Text('Re-scored $rescored claim${rescored == 1 ? '' : 's'} across $users user${users == 1 ? '' : 's'}.'),
            ],
            const SizedBox(height: 12),
            if (editUrl != null)
              OutlinedButton.icon(
                onPressed: () => launchUrl(Uri.parse(editUrl), mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open in the OSM editor'),
              ),
            if (oscPath != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: Text('osmChange: $oscPath', style: Theme.of(ctx).textTheme.bodySmall)),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: 'Copy storage path',
                    onPressed: () => Clipboard.setData(ClipboardData(text: oscPath)),
                  ),
                ],
              ),
            ],
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
      ),
    );
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
          Expanded(child: DefaultTextStyle.merge(style: Theme.of(context).textTheme.bodyMedium, child: child)),
        ],
      ),
    );
  }
}

class _ReviewOutcome extends StatelessWidget {
  const _ReviewOutcome({required this.data});
  final Map<String, dynamic> data;
  @override
  Widget build(BuildContext context) {
    final status = data['status'] as String?;
    final reviewNote = data['reviewNote'] as String?;
    final editUrl = data['osmEditUrl'] as String?;
    final oscPath = data['osmChangesetPath'] as String?;
    final accepted = status == 'accepted';
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: (accepted ? Colors.green : Colors.redAccent).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(accepted ? 'Accepted' : 'Rejected', style: TextStyle(fontWeight: FontWeight.bold, color: accepted ? Colors.green[800] : Colors.red[800])),
          if (reviewNote != null && reviewNote.isNotEmpty) Text(reviewNote),
          if (accepted && editUrl != null)
            TextButton.icon(
              onPressed: () => launchUrl(Uri.parse(editUrl), mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('OSM editor'),
            ),
          if (accepted && oscPath != null) Text('osmChange: $oscPath', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _PhotoThumb extends StatelessWidget {
  const _PhotoThumb({required this.photo});
  final Map<String, dynamic> photo;

  @override
  Widget build(BuildContext context) {
    final path = photo['storagePath'] as String?;
    final hasGps = photo['exifLat'] != null && photo['exifLng'] != null;
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: GestureDetector(
        onTap: path == null ? null : () => _open(context, path),
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 84,
                height: 84,
                child: path == null
                    ? const ColoredBox(color: Colors.black12, child: Icon(Icons.broken_image_outlined))
                    : FutureBuilder<String>(
                        future: FirebaseStorage.instance.ref(path).getDownloadURL(),
                        builder: (_, s) => s.hasData
                            // Decode at thumbnail size — uploaded photos can
                            // be 2400 px on the long edge, which would chew
                            // many MB of decoded bitmap per row in the queue.
                            ? Image.network(s.data!,
                                fit: BoxFit.cover,
                                cacheWidth: 168,
                                cacheHeight: 168)
                            : const ColoredBox(color: Colors.black12, child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))),
                      ),
              ),
            ),
            if (hasGps)
              const Positioned(left: 3, bottom: 3, child: Icon(Icons.location_on, size: 14, color: Colors.white, shadows: [Shadow(blurRadius: 3)])),
          ],
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, String path) async {
    final url = await FirebaseStorage.instance.ref(path).getDownloadURL();
    if (!context.mounted) return;
    final exifLat = (photo['exifLat'] as num?)?.toDouble();
    final exifLng = (photo['exifLng'] as num?)?.toDouble();
    final takenAt = photo['takenAt'] as String?;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: InteractiveViewer(child: Image.network(url))),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (exifLat != null && exifLng != null)
                    Text('Photo EXIF GPS: ${exifLat.toStringAsFixed(6)}, ${exifLng.toStringAsFixed(6)}')
                  else
                    const Text('No GPS in this photo\'s EXIF.'),
                  if (takenAt != null) Text('Taken: $takenAt'),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── accept dialog ────────────────────────────────────────────────────────────

class _AcceptResult {
  _AcceptResult({required this.cypher, this.reference, this.reviewNote});
  final String cypher; // notSureCypher | plainCypher | a key
  final String? reference;
  final String? reviewNote;
}

class _AcceptDialog extends StatefulWidget {
  const _AcceptDialog({required this.isCypherReport, required this.initialCypher});
  final bool isCypherReport;
  final String initialCypher;
  @override
  State<_AcceptDialog> createState() => _AcceptDialogState();
}

class _AcceptDialogState extends State<_AcceptDialog> {
  late String _cypher = widget.initialCypher;
  final _refController = TextEditingController();
  final _noteController = TextEditingController();

  @override
  void dispose() {
    _refController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Accept report'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.isCypherReport
                  ? 'Confirm the correct cypher. The Firestore postbox is updated and, if the points value changes, every past claim on it is re-scored.'
                  : 'Optionally set the cypher for the new postbox. An osmChange file and an editor link are generated for you to add it to OSM.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.md),
            CypherPicker(value: _cypher, label: 'Final cypher', onChanged: (v) => setState(() => _cypher = v)),
            const SizedBox(height: AppSpacing.sm),
            TextField(controller: _refController, maxLength: 40, decoration: const InputDecoration(labelText: 'Reference / plate (optional)')),
            TextField(controller: _noteController, maxLength: 280, decoration: const InputDecoration(labelText: 'Note to reporter (optional)')),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (widget.isCypherReport && _cypher == notSureCypher) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Choose the correct cypher (or "Plain / no cypher").')));
              return;
            }
            Navigator.pop(context, _AcceptResult(cypher: _cypher, reference: _refController.text.trim(), reviewNote: _noteController.text.trim()));
          },
          child: const Text('Accept'),
        ),
      ],
    );
  }
}
