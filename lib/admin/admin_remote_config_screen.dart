import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:postbox_game/admin/admin_access.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/analytics_user_properties.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/theme.dart';

/// Read-only debug view of the live Remote Config values, gated on the `admin`
/// custom claim. Edits happen in the Firebase Console — this screen exists to
/// verify what the device is actually serving.
class AdminRemoteConfigScreen extends StatefulWidget {
  const AdminRemoteConfigScreen({super.key});

  @override
  State<AdminRemoteConfigScreen> createState() =>
      _AdminRemoteConfigScreenState();
}

class _AdminRemoteConfigScreenState extends State<AdminRemoteConfigScreen> {
  // Mirrors AdminReportsScreen: force a token refresh once on entry so a
  // freshly-granted claim resolves, then cache the result.
  late final Future<bool> _adminCheck = AdminAccess.isAdmin(forceRefresh: true);
  bool _refreshing = false;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _adminCheck,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator(color: postalRed)),
          );
        }
        if (snap.data != true) {
          return Scaffold(
            appBar: AppBar(title: const Text('Remote Config')),
            body: const Center(
              child: Text('You do not have access to this area.'),
            ),
          );
        }
        return _buildAdminBody(context);
      },
    );
  }

  Widget _buildAdminBody(BuildContext context) {
    final rc = RemoteConfigService.instance;
    final entries = rc.snapshot();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin · Remote Config'),
        actions: [
          IconButton(
            tooltip: 'Force refresh now',
            icon: _refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _refreshing ? null : _forceRefresh,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          _MetaCard(
            lastFetchStatus: rc.lastFetchStatus,
            lastFetchTime: rc.lastFetchTime,
          ),
          const SizedBox(height: AppSpacing.md),
          _UserPropertiesCard(
              properties: Analytics.lastSetUserProperties),
          const SizedBox(height: AppSpacing.md),
          for (final entry in entries) ...[
            _EntryCard(entry: entry),
            const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ),
    );
  }

  Future<void> _forceRefresh() async {
    setState(() => _refreshing = true);
    final activated = await RemoteConfigService.instance.forceRefresh();
    if (!mounted) return;
    setState(() => _refreshing = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(activated
          ? 'Activated new values from the server.'
          : 'No new values (or fetch failed). Showing current cache.'),
    ));
  }
}

class _MetaCard extends StatelessWidget {
  const _MetaCard({required this.lastFetchStatus, required this.lastFetchTime});

  final RemoteConfigFetchStatus lastFetchStatus;
  final DateTime lastFetchTime;

  @override
  Widget build(BuildContext context) {
    // The plugin returns the unix epoch when no fetch has ever completed —
    // surface that explicitly instead of showing "1970".
    final everFetched = lastFetchTime.millisecondsSinceEpoch > 0;
    final when = everFetched
        ? DateFormat.yMMMd().add_Hms().format(lastFetchTime.toLocal())
        : 'never';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Fetch metadata',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Text('Last fetch: $when'),
            Text('Status: ${lastFetchStatus.name}'),
          ],
        ),
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({required this.entry});

  final RemoteConfigEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final source = _sourceLabel(entry.source);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(entry.key, style: theme.textTheme.titleMedium),
                ),
                _SourceChip(label: source, isDefault: entry.usingDefault),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text('Value: ${entry.value}', style: theme.textTheme.bodyMedium),
            Text(
              'Default: ${entry.defaultValue}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _sourceLabel(ValueSource s) => switch (s) {
        ValueSource.valueRemote => 'remote',
        ValueSource.valueDefault => 'default',
        ValueSource.valueStatic => 'static',
      };
}

class _UserPropertiesCard extends StatelessWidget {
  const _UserPropertiesCard({required this.properties});

  /// Snapshot of `Analytics.lastSetUserProperties` taken when this card was
  /// built. A subsequent push (e.g. after a claim) won't update the live UI
  /// until the screen rebuilds — refresh by tapping the AppBar refresh icon
  /// or by navigating away and back.
  final Map<String, String?> properties;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Analytics user properties',
                style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Audience values reported to Firebase Analytics for Remote Config targeting.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            for (final key in AnalyticsUserProps.all)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(key,
                          style: theme.textTheme.bodyMedium?.copyWith(
                              fontFeatures: const [FontFeature.tabularFigures()])),
                    ),
                    Text(
                      properties[key] ?? 'unset',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: properties.containsKey(key)
                            ? null
                            : theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
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

class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.label, required this.isDefault});
  final String label;
  final bool isDefault;
  @override
  Widget build(BuildContext context) {
    final colour = isDefault ? Colors.grey : postalRed;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style:
            TextStyle(color: colour, fontWeight: FontWeight.w600, fontSize: 12),
      ),
    );
  }
}
