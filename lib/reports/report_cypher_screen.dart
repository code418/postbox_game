import 'package:flutter/material.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/reports/report_form_widgets.dart';
import 'package:postbox_game/reports/report_repository.dart';
import 'package:postbox_game/theme.dart';

/// Form for reporting that a claimed postbox has the wrong (or missing) royal
/// cypher. Opened from the History screen's postbox detail.
class ReportCypherScreen extends StatefulWidget {
  const ReportCypherScreen({
    super.key,
    required this.postboxId,
    this.currentMonarch,
    this.reference,
  });

  /// Firestore postbox document id (e.g. `osm_123456`).
  final String postboxId;
  final String? currentMonarch;
  final String? reference;

  @override
  State<ReportCypherScreen> createState() => _ReportCypherScreenState();
}

class _ReportCypherScreenState extends State<ReportCypherScreen> {
  final _noteController = TextEditingController();
  late final _referenceController = TextEditingController(text: widget.reference ?? '');
  late String _cypher = _initialCypher();
  List<PendingPhoto> _photos = const [];
  bool _submitting = false;

  String _initialCypher() {
    final m = widget.currentMonarch;
    if (m != null && MonarchInfo.labels.containsKey(m)) return m;
    return notSureCypher;
  }

  @override
  void dispose() {
    _noteController.dispose();
    _referenceController.dispose();
    super.dispose();
  }

  bool get _hasSomething =>
      _cypher != notSureCypher || _noteController.text.trim().isNotEmpty || _photos.isNotEmpty;

  Future<void> _submit() async {
    if (!_hasSomething) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick the correct cypher, add a note, or attach a photo first.')),
      );
      return;
    }
    setState(() => _submitting = true);
    try {
      await ReportRepository.submitWrongCypher(
        postboxId: widget.postboxId,
        note: _noteController.text,
        suggestedMonarch: _cypher == notSureCypher ? null : _cypher,
        suggestedReference: _referenceController.text,
        photos: _photos,
      );
      if (!mounted) return;
      await showReportThanksDialog(context);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not send report: $e')));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentLabel = widget.currentMonarch != null
        ? (MonarchInfo.labels[widget.currentMonarch!] ?? widget.currentMonarch!)
        : 'No cypher recorded';
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.currentMonarch == null
            ? 'Report missing cypher'
            : 'Report wrong cypher'),
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              Card(
                child: ListTile(
                  leading: const Icon(Icons.markunread_mailbox_outlined, color: postalRed),
                  title: Text('Currently recorded as: $currentLabel'),
                  subtitle: (widget.reference != null && widget.reference!.isNotEmpty)
                      ? Text('Ref ${widget.reference}')
                      : null,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              CypherPicker(value: _cypher, onChanged: (v) => setState(() => _cypher = v)),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'If accepted, every past claim on this box is re-scored — yours and other players\'.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _referenceController,
                maxLength: 40,
                decoration: const InputDecoration(
                  labelText: 'Correct reference / plate number (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _noteController,
                maxLength: 280,
                maxLines: 3,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              PhotoPickerField(photos: _photos, onChanged: (p) => setState(() => _photos = p)),
              const SizedBox(height: AppSpacing.xl),
              FilledButton.icon(
                onPressed: _submitting ? null : _submit,
                icon: const Icon(Icons.send),
                label: const Text('Send report'),
              ),
              const SizedBox(height: AppSpacing.xxl),
            ],
          ),
          if (_submitting)
            const ColoredBox(
              color: Colors.black38,
              child: Center(child: CircularProgressIndicator(color: postalRed)),
            ),
        ],
      ),
    );
  }
}
