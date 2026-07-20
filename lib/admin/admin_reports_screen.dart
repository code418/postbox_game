import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:postbox_game/firebase_functions_eu.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:postbox_game/admin/admin_access.dart';
import 'package:postbox_game/maintenance_guard.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/reports/report_form_widgets.dart';
import 'package:postbox_game/reports/report_repository.dart'
    show ReportRepository, plainCypher;
import 'package:postbox_game/theme.dart';
import 'package:url_launcher/url_launcher.dart';

/// In-app review queue for postbox-data problem reports. Visible only to users
/// holding the `admin` custom claim (see [AdminAccess]). Accepting a report
/// calls the `reviewReport` Cloud Function, which updates the Firestore postbox
/// entry, re-scores affected claims, and generates an osmChange file.
class AdminReportsScreen extends StatefulWidget {
  const AdminReportsScreen({super.key});

  @override
  State<AdminReportsScreen> createState() => _AdminReportsScreenState();
}

class _AdminReportsScreenState extends State<AdminReportsScreen> {
  static const _statuses = ['pending', 'accepted', 'rejected'];
  static const _labels = {'pending': 'Pending', 'accepted': 'Accepted', 'rejected': 'Rejected'};

  // Force a token refresh once on entry to pick up a freshly-granted admin
  // claim, then cache the result so a Theme/orientation rebuild doesn't
  // re-issue `getIdTokenResult(forceRefresh: true)` (a Firebase Auth network
  // round-trip).
  late final Future<bool> _adminCheck =
      AdminAccess.isAdmin(forceRefresh: true);

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
            appBar: AppBar(title: const Text('Report review')),
            body: const Center(child: Text('You do not have access to this area.')),
          );
        }
        return DefaultTabController(
          length: _statuses.length,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Report review'),
              bottom: TabBar(
                tabs: [for (final s in _statuses) _CountedTab(status: s, label: _labels[s]!)],
              ),
            ),
            body: TabBarView(children: [for (final s in _statuses) _ReportList(status: s)]),
          ),
        );
      },
    );
  }
}

/// The query behind both a tab's count badge and its list. Firestore shares a
/// single underlying listener for identical queries, so the badge costs no
/// extra reads on top of the list it labels.
Query<Map<String, dynamic>> _reportsQuery(String status) =>
    FirebaseFirestore.instance.collection('reports').where('status', isEqualTo: status);

/// Tab label carrying a live count, so an admin can see the size of the review
/// backlog without opening each tab.
class _CountedTab extends StatelessWidget {
  const _CountedTab({required this.status, required this.label});
  final String status;
  final String label;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _reportsQuery(status).snapshots(),
      builder: (context, snap) {
        final count = snap.data?.docs.length;
        return Tab(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
              if (count != null && count > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: postalRed,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$count',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
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
      stream: _reportsQuery(status).snapshots(),
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
        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  status == 'pending' ? Icons.inbox_outlined : Icons.history_outlined,
                  size: 48,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  status == 'pending' ? 'Nothing to review' : 'No $status reports',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (status == 'pending')
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'The review queue is empty.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          );
        }
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
    final createdLocal = created is Timestamp ? created.toDate().toLocal() : null;
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
                if (createdLocal != null)
                  // Relative age is what matters when triaging a queue ("how
                  // stale is this?"); the exact timestamp stays available as a
                  // long-press tooltip.
                  Tooltip(
                    message: DateFormat.yMMMd().add_jm().format(createdLocal),
                    child: Text(_relativeAge(createdLocal), style: theme.textTheme.bodySmall),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (isMissing && _lat != null && _lng != null)
              _InfoRow(
                icon: Icons.place_outlined,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_lat!.toStringAsFixed(5)}, ${_lng!.toStringAsFixed(5)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (d['accuracyMeters'] is num) ...[
                      const SizedBox(width: 6),
                      _AccuracyChip(metres: (d['accuracyMeters'] as num).toDouble()),
                    ],
                    TextButton(
                      onPressed: () => _openMap(_lat!, _lng!),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                      ),
                      child: const Text('Map'),
                    ),
                  ],
                ),
              ),
            if (!isMissing)
              _InfoRow(
                icon: Icons.markunread_mailbox_outlined,
                child: Row(
                  children: [
                    Expanded(child: Text('Recorded: ${_monarchLabel(d['currentMonarch'])}')),
                    // A cypher report names an existing OSM node, so the
                    // reviewer can jump straight to it to check the plate
                    // against what the reporter claims.
                    if (d['overpassId'] is num)
                      TextButton(
                        onPressed: () => _openOsmNode((d['overpassId'] as num).toInt()),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                        ),
                        child: const Text('OSM'),
                      ),
                  ],
                ),
              ),
            if (!isMissing && d['postboxId'] != null)
              _InfoRow(
                icon: Icons.fingerprint,
                child: Text('Postbox ${d['postboxId']}', style: theme.textTheme.bodySmall),
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
              // Both buttons are wrapped in Expanded deliberately. The app
              // theme gives FilledButton/OutlinedButton a
              // `minimumSize: Size(double.infinity, 52)` so CTAs stretch inside
              // a Column; a bare Row hands its children an UNBOUNDED width, and
              // that tight-infinite minimum then throws "BoxConstraints forces
              // an infinite width" — which silently blanked this whole list.
              // Expanded supplies a bounded width and keeps the row balanced.
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : _reject,
                      child: const Text('Reject'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy ? null : _accept,
                      child: _busy
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Accept'),
                    ),
                  ),
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
    await _launch(uri);
  }

  Future<void> _openOsmNode(int overpassId) =>
      _launch(Uri.parse('https://www.openstreetmap.org/node/$overpassId'));

  Future<void> _launch(Uri uri) async {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open the map')));
    }
  }

  Future<void> _reject() async {
    if (MaintenanceGuard.blocked(context, actionLabel: 'review reports')) {
      return;
    }
    final noteController = TextEditingController();
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Reject report'),
          content: TextField(
            controller: noteController,
            maxLength: ReportRepository.maxNoteChars,
            decoration: const InputDecoration(labelText: 'Reason (optional, shown to the reporter)'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: dialogActionStyle(),
              child: const Text('Reject'),
            ),
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
    if (MaintenanceGuard.blocked(context, actionLabel: 'review reports')) {
      return;
    }
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
      final res = await appFunctions.httpsCallable('reviewReport').call(payload);
      if (!mounted) return;
      if (isAccept) {
        final m = Map<String, dynamic>.from(res.data as Map);
        await _showAcceptedDialog(m);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report rejected')));
      }
    } on FirebaseFunctionsException catch (e) {
      // Admins benefit from seeing the typed error message + code for triage,
      // but not the raw toString (which prefixes "FirebaseFunctionsException
      // (...)" and includes the stack location).
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Failed: ${e.message ?? e.code}')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Failed. Please try again.')));
      }
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

/// Compact "2d ago" style age for the review queue.
String _relativeAge(DateTime when) {
  final diff = DateTime.now().difference(when);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 30) return '${diff.inDays}d ago';
  return DateFormat.yMMMd().format(when);
}

/// GPS accuracy of the reporter's fix, colour-coded. Accepting a "missing
/// postbox" report writes these coordinates straight into Firestore, so a
/// sloppy fix is the single most important quality signal on the card.
class _AccuracyChip extends StatelessWidget {
  const _AccuracyChip({required this.metres});
  final double metres;

  @override
  Widget build(BuildContext context) {
    final (color, hint) = switch (metres) {
      < 10 => (Colors.green, 'Good GPS fix'),
      < 25 => (Colors.orange, 'Fair GPS fix — check against the photo'),
      _ => (Colors.redAccent, 'Poor GPS fix — verify before accepting'),
    };
    return Tooltip(
      message: hint,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          '±${metres.round()} m',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
        ),
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
          if (accepted && oscPath != null)
            // Match the post-accept dialog: surface the storage path with a
            // copy button so the admin can paste it into the Firebase console
            // to download the .osc, rather than scraping it from the text.
            Row(
              children: [
                Expanded(
                  child: Text('osmChange: $oscPath',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: 'Copy storage path',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => Clipboard.setData(ClipboardData(text: oscPath)),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _PhotoThumb extends StatefulWidget {
  const _PhotoThumb({required this.photo});
  final Map<String, dynamic> photo;

  @override
  State<_PhotoThumb> createState() => _PhotoThumbState();
}

class _PhotoThumbState extends State<_PhotoThumb> {
  /// Cached download URL future — built once per path so a parent rebuild
  /// (Accept tap, photo dialog open, sibling busy toggling) doesn't fire a
  /// fresh Storage round-trip per thumb on every frame.
  Future<String>? _urlFuture;
  String? _lastPath;

  /// EXIF GPS, but only when it is real. A camera that reports no fix writes
  /// 0/0 into the tags, and "Null Island" off West Africa is never a valid
  /// UK postbox — showing it as a location badge would tell a reviewer the
  /// photo corroborates the report when it does nothing of the kind.
  double? get _exifLat => _realCoord(widget.photo['exifLat'], widget.photo['exifLng']);
  double? get _exifLng => _realCoord(widget.photo['exifLng'], widget.photo['exifLat']);

  static double? _realCoord(Object? value, Object? other) {
    if (value is! num || other is! num) return null;
    if (value == 0 && other == 0) return null;
    return value.toDouble();
  }

  Future<String> _urlFor(String path) {
    if (_urlFuture == null || _lastPath != path) {
      _lastPath = path;
      _urlFuture = FirebaseStorage.instance.ref(path).getDownloadURL();
    }
    return _urlFuture!;
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.photo['storagePath'] as String?;
    final hasGps = _exifLat != null && _exifLng != null;
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      // Tooltip provides the assistive-tech label for the photo thumbnail —
      // without it, a screen reader on the admin screen would announce just
      // "image" with no hint that tapping opens the full-size view.
      child: Tooltip(
        message: 'View photo',
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
                        future: _urlFor(path),
                        builder: (_, s) => s.hasData
                            // Decode at thumbnail size — uploaded photos can
                            // be 2400 px on the long edge, which would chew
                            // many MB of decoded bitmap per row in the queue.
                            ? Image.network(s.data!,
                                fit: BoxFit.cover,
                                cacheWidth: 168,
                                cacheHeight: 168,
                                // Without this a failed download renders as an
                                // invisible 84px hole, which reads as "this
                                // report has no photo" rather than "the photo
                                // could not be loaded".
                                errorBuilder: (_, __, ___) => const ColoredBox(
                                  color: Colors.black12,
                                  child: Center(
                                    child: Icon(Icons.broken_image_outlined, size: 22),
                                  ),
                                ))
                            : ColoredBox(
                                color: Colors.black12,
                                child: Center(
                                  child: s.hasError
                                      ? const Icon(Icons.broken_image_outlined, size: 22)
                                      : const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(strokeWidth: 2),
                                        ),
                                ),
                              ),
                      ),
              ),
            ),
            if (hasGps)
              const Positioned(left: 3, bottom: 3, child: Icon(Icons.location_on, size: 14, color: Colors.white, shadows: [Shadow(blurRadius: 3)])),
          ],
        ),
      ),
      ),
    );
  }

  Future<void> _open(BuildContext context, String path) async {
    // Reuse the cached URL future (same Storage download URL) instead of
    // firing a fresh getDownloadURL request on every tap.
    final url = await _urlFor(path);
    if (!context.mounted) return;
    final exifLat = _exifLat;
    final exifLng = _exifLng;
    final takenAt = widget.photo['takenAt'] as String?;
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
            TextField(controller: _refController, maxLength: ReportRepository.maxReferenceChars, decoration: const InputDecoration(labelText: 'Reference / plate (optional)')),
            TextField(controller: _noteController, maxLength: ReportRepository.maxNoteChars, decoration: const InputDecoration(labelText: 'Note to reporter (optional)')),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          style: dialogActionStyle(),
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
