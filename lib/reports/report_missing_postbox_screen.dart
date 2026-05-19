import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/location_service.dart';
import 'package:postbox_game/maintenance_guard.dart';
import 'package:postbox_game/reports/report_form_widgets.dart';
import 'package:postbox_game/reports/report_repository.dart';
import 'package:postbox_game/theme.dart';

/// Form for reporting a postbox that exists in the real world but didn't show
/// up in the claim scan. Captures the user's GPS as the authoritative location
/// (with an optional note, suggested cypher, and geotagged photos).
class ReportMissingPostboxScreen extends StatefulWidget {
  const ReportMissingPostboxScreen({super.key, this.initialPosition});

  /// Pre-filled position (e.g. the Claim screen's scan position). If null the
  /// screen fetches a fresh fix on open.
  final Position? initialPosition;

  @override
  State<ReportMissingPostboxScreen> createState() => _ReportMissingPostboxScreenState();
}

class _ReportMissingPostboxScreenState extends State<ReportMissingPostboxScreen> {
  final _noteController = TextEditingController();
  String _cypher = notSureCypher;
  String _reference = '';
  List<PendingPhoto> _photos = const [];

  Position? _position;
  String? _locationError;
  bool _locating = false;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _position = widget.initialPosition;
    if (_position == null) _fetchLocation();
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _fetchLocation() async {
    // Guard against rapid double-taps on the Refresh button firing two
    // concurrent getPosition() calls whose results race to setState (a
    // slower failure could otherwise overwrite a faster success).
    if (_locating) return;
    setState(() {
      _locating = true;
      _locationError = null;
    });
    try {
      final pos = await getPosition();
      if (mounted) setState(() => _position = pos);
    } on LocationServiceException catch (e) {
      // Surface the typed [message] instead of the toString() (which is
      // prefixed with the class name + kind enum — verbose and unhelpful in
      // a UI banner).
      if (e.kind == LocationErrorKind.permissionPermanentlyDenied) {
        unawaited(Analytics.locationPermissionPermanentlyDenied());
      }
      if (mounted) setState(() => _locationError = e.message);
    } catch (_) {
      if (mounted) {
        setState(() =>
            _locationError = 'Could not determine your location. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _submit() async {
    final pos = _position;
    if (pos == null) return;
    if (MaintenanceGuard.blocked(context, actionLabel: 'send a report')) {
      return;
    }
    setState(() => _submitting = true);
    try {
      await ReportRepository.submitMissingPostbox(
        lat: pos.latitude,
        lng: pos.longitude,
        accuracyMeters: pos.accuracy.isFinite ? pos.accuracy : null,
        note: _noteController.text,
        suggestedMonarch: _cypher == notSureCypher ? null : _cypher,
        suggestedReference: _reference,
        photos: _photos,
      );
      unawaited(Analytics.reportSubmitted(
        type: 'missing_postbox',
        photoCount: _photos.length,
      ));
      if (!mounted) return;
      await showReportThanksDialog(context);
      if (mounted) Navigator.of(context).pop(true);
    } on FirebaseFunctionsException catch (e) {
      unawaited(Analytics.reportSubmitFailed(
        type: 'missing_postbox',
        reason: e.code.isNotEmpty ? e.code : 'unknown',
      ));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not send report: ${e.message ?? e.code}')));
      }
    } catch (_) {
      unawaited(Analytics.reportSubmitFailed(
        type: 'missing_postbox',
        reason: 'unknown',
      ));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not send report. Please try again.')));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pos = _position;
    return Scaffold(
      appBar: AppBar(title: const Text('Report a missing postbox')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              Text(
                'See a real postbox here that the app missed? Stand next to it and send a report — '
                'we use your location to add it.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.lg),
              _LocationCard(
                position: pos,
                locating: _locating,
                error: _locationError,
                onRetry: _fetchLocation,
              ),
              const SizedBox(height: AppSpacing.lg),
              CypherPicker(
                value: _cypher,
                label: 'Cypher on the box (if you can tell)',
                onChanged: (v) => setState(() => _cypher = v),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                onChanged: (v) => _reference = v,
                maxLength: ReportRepository.maxReferenceChars,
                decoration: const InputDecoration(
                  labelText: 'Postbox reference / plate number (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _noteController,
                maxLength: ReportRepository.maxNoteChars,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Anything else? (optional)',
                  hintText: 'e.g. on the wall outside the Co-op',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              PhotoPickerField(photos: _photos, onChanged: (p) => setState(() => _photos = p)),
              const SizedBox(height: AppSpacing.xl),
              FilledButton.icon(
                onPressed: (pos == null || _submitting) ? null : _submit,
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

class _LocationCard extends StatelessWidget {
  const _LocationCard({required this.position, required this.locating, required this.error, required this.onRetry});
  final Position? position;
  final bool locating;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            const Icon(Icons.my_location, color: postalRed),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: locating
                  ? const Text('Getting your location…')
                  : error != null
                      ? Text('Location unavailable: $error', style: TextStyle(color: theme.colorScheme.error))
                      : position != null
                          ? Text(
                              '${position!.latitude.toStringAsFixed(5)}, ${position!.longitude.toStringAsFixed(5)}'
                              '${position!.accuracy.isFinite ? '  ·  ±${position!.accuracy.round()} m' : ''}',
                              style: theme.textTheme.bodyMedium,
                            )
                          : const Text('No location yet'),
            ),
            if (!locating)
              IconButton(onPressed: onRetry, icon: const Icon(Icons.refresh), tooltip: 'Refresh location'),
          ],
        ),
      ),
    );
  }
}
