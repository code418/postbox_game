import 'dart:async';

import 'package:flutter/material.dart';
import 'package:postbox_game/activity/activity_claim_sheet.dart';
import 'package:postbox_game/activity/activity_helpers.dart';
import 'package:postbox_game/firebase_functions_eu.dart';
import 'package:postbox_game/james_controller.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/james_strip.dart';
import 'package:postbox_game/legal/privacy_policy_screen.dart';
import 'package:postbox_game/services/activity_claims_service.dart';
import 'package:postbox_game/services/activity_store.dart';
import 'package:postbox_game/services/health_connect_bridge.dart';
import 'package:postbox_game/theme.dart';

/// "Claim from your workouts": connect Health Connect, see recent walks /
/// runs / hikes, and claim the postboxes they passed (after the cypher quiz).
class ActivityClaimsScreen extends StatefulWidget {
  const ActivityClaimsScreen({super.key, this.service});

  final ActivityClaimsService? service;

  @override
  State<ActivityClaimsScreen> createState() => _ActivityClaimsScreenState();
}

class _ActivityClaimsScreenState extends State<ActivityClaimsScreen> with WidgetsBindingObserver {
  late final ActivityClaimsService _service = widget.service ?? ActivityClaimsService.instance;
  final JamesController _james = JamesController();

  bool _loading = true;
  bool _checking = false;
  bool _autoRefreshed = false;
  HcAvailability _availability = HcAvailability.unsupported;
  Set<String> _granted = const {};
  bool _optedIn = false;
  ActivityState _state = ActivityState();

  bool get _connected => _optedIn && _granted.contains(HealthConnectPermissions.readExercise);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _james.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pick up changes made in Health Connect's own settings / install page.
    if (state == AppLifecycleState.resumed) unawaited(_load());
  }

  Future<void> _load() async {
    final availability = await _service.availability();
    final granted = availability == HcAvailability.available ? await _service.grantedPermissions() : <String>{};
    final optedIn = await _service.optedIn();
    final state = await _service.loadState();
    if (!mounted) return;
    setState(() {
      _availability = availability;
      _granted = granted;
      _optedIn = optedIn;
      _state = state;
      _loading = false;
    });
    if (_connected && !_autoRefreshed) {
      _autoRefreshed = true;
      unawaited(_refresh());
    }
  }

  Future<void> _connect() async {
    final granted = await _service.connect();
    if (!mounted) return;
    if (granted.contains(HealthConnectPermissions.readExercise)) {
      _james.show(JamesMessages.activityConnected.resolve());
      _autoRefreshed = false;
    } else {
      _snack("Health Connect access wasn't granted. You can try again any time.");
    }
    await _load();
  }

  Future<void> _refresh() async {
    if (_checking) return;
    setState(() => _checking = true);
    final summary = await _service.refresh();
    await _afterCheck(summary);
  }

  Future<void> _checkWithConsent(HcSession s) async {
    if (_checking) return;
    setState(() => _checking = true);
    final summary = await _service.checkWithConsent(s);
    await _afterCheck(summary);
  }

  Future<void> _afterCheck(ActivityCheckSummary summary) async {
    final state = await _service.loadState();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _state = state;
    });
    if (summary.newCandidates > 0) {
      _james.show(JamesMessages.activityCandidatesFound(summary.newCandidates));
    } else if (summary.error == null && summary.checked > 0 &&
        _state.claimable(DateTime.now().millisecondsSinceEpoch, _service.graceMs).isEmpty) {
      _james.show(JamesMessages.activityNoneFound.resolve());
    }
    final msg = switch (summary.error) {
      null => null,
      'offline' => "You're offline. We'll check your workouts when you're back.",
      'quota_exceeded' => "That's enough workouts checked for today. More tomorrow.",
      'not_available' => "Workout claims aren't available right now.",
      'maintenance' => "We're doing a spot of maintenance. Try again shortly.",
      'app_verification' => appVerificationMessage,
      'permission_denied' => 'Health Connect access was turned off. Reconnect to carry on.',
      _ => "Couldn't check your workouts just now. Try again in a bit.",
    };
    if (msg != null) _snack(msg);
  }

  Future<void> _openClaim(ActivityCandidate c) async {
    await ActivityClaimSheet.show(context, c, james: _james, service: _service);
    final state = await _service.loadState();
    if (mounted) setState(() => _state = state);
  }

  void _snack(String msg) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Claim from your workouts')),
      body: Stack(
        children: [
          Positioned.fill(child: _loading ? const Center(child: CircularProgressIndicator()) : _content(context)),
          // Pushed route outside Home's JamesControllerScope: own strip.
          Positioned(left: 0, right: 0, bottom: 0, child: JamesStrip(controller: _james)),
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
    if (!_service.featureVisible || _availability == HcAvailability.unsupported) {
      return _message(context, Icons.phonelink_off,
          "Workout claims need Android with Health Connect. They aren't available on this device.");
    }
    if (_availability == HcAvailability.notInstalled || _availability == HcAvailability.updateRequired) {
      final update = _availability == HcAvailability.updateRequired;
      return _message(
        context,
        Icons.health_and_safety_outlined,
        update
            ? 'Health Connect needs an update before we can read your workouts.'
            : 'Workout claims use Health Connect, which is free from Google Play.',
        action: FilledButton(
          onPressed: () => _service.bridge.openInstall(),
          child: Text(update ? 'Update Health Connect' : 'Get Health Connect'),
        ),
      );
    }
    if (!_connected) return _connectPanel(context);
    return RefreshIndicator(onRefresh: _refresh, child: _connectedList(context));
  }

  Widget _message(BuildContext context, IconData icon, String text, {Widget? action}) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.xxl, AppSpacing.xl, kJamesStripClearance),
      children: [
        Icon(icon, size: 56, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(height: AppSpacing.md),
        Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
        if (action != null) ...[const SizedBox(height: AppSpacing.lg), action],
      ],
    );
  }

  /// The prominent disclosure shown before Health Connect's own prompt.
  Widget _connectPanel(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hours = _service.graceMs ~/ 3600000;
    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, kJamesStripClearance),
      children: [
        const Icon(Icons.directions_run, size: 56, color: postalRed),
        const SizedBox(height: AppSpacing.md),
        Text('Claim postboxes you passed on a walk or run',
            textAlign: TextAlign.center, style: t.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: AppSpacing.md),
        Text(
          'Record a walk, run or hike with Fitbit, Samsung Health, Garmin or another fitness app '
          'that shares to Health Connect. If your route passed an unclaimed postbox, you can claim '
          'it here for the day you passed it, once you tell us its cypher.',
          style: t.bodyMedium,
        ),
        const SizedBox(height: AppSpacing.md),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('What we read, and why', style: t.titleSmall),
                const SizedBox(height: AppSpacing.sm),
                _bullet('Your walks, runs and hikes from the last $hours hours: type, start and end time, and which app recorded them.'),
                _bullet('Their GPS routes, only while this app is open.'),
                _bullet('Each new route is sent once to our server to find postboxes within 30 m of it, then discarded. It is never stored.'),
                _bullet('Only the spot where you passed a postbox you choose to claim is kept, with that claim, for 90 days.'),
                _bullet('Nothing is written to Health Connect, and nothing is used for advertising.'),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        FilledButton.icon(
          onPressed: _connect,
          icon: const Icon(Icons.link),
          label: const Text('Connect Health Connect'),
        ),
        TextButton(
          onPressed: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen())),
          child: const Text('Privacy policy'),
        ),
      ],
    );
  }

  Widget _bullet(String text) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [const Text('•  '), Expanded(child: Text(text))],
        ),
      );

  Widget _connectedList(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final now = DateTime.now().millisecondsSinceEpoch;
    final claimable = _state.claimable(now, _service.graceMs);
    final claimedKeys = _state.claimed.keys.toSet();
    final claimedCandidates = _state.candidates.where((c) => claimedKeys.contains(c.key)).toList()
      ..sort((a, b) => b.passedAtMs.compareTo(a.passedAtMs));
    final sessions = _state.sessions.values.toList()
      ..sort((a, b) => b.session.endMs.compareTo(a.session.endMs));
    final routesAlways = _granted.contains(HealthConnectPermissions.readExerciseRoutes);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: kJamesStripClearance),
      children: [
        if (_checking) const LinearProgressIndicator(),
        if (!routesAlways)
          ListTile(
            leading: const Icon(Icons.route_outlined),
            title: const Text('Allow route access for every workout'),
            subtitle: const Text(
                "Otherwise Health Connect asks each time, and new workouts wait until you tap Check."),
            trailing: FilledButton.tonal(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: () => _service.bridge.openSettings(),
              child: const Text('Open'),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
          child: Text('Ready to claim', style: t.titleMedium),
        ),
        if (claimable.isEmpty)
          const ListTile(
            leading: Icon(Icons.inbox_outlined),
            title: Text('Nothing to claim right now'),
            subtitle: Text('Pull down to check for new workouts.'),
          )
        else
          for (final c in claimable) _candidateTile(context, c),
        if (claimedCandidates.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
            child: Text('Claimed', style: t.titleMedium),
          ),
          for (final c in claimedCandidates)
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: Text('${c.boxes.length == 1 ? 'Postbox' : '${c.boxes.length} postboxes'} at ${clockTime(c.passedAtMs)}'),
              subtitle: Text('${sessionNoun(c.exerciseType)} · ${c.claimDate}'),
            ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
          child: Text('Recent workouts', style: t.titleMedium),
        ),
        if (sessions.isEmpty)
          const ListTile(
            leading: Icon(Icons.directions_walk),
            title: Text('No workouts checked yet'),
            subtitle: Text('Walks, runs and hikes from the last day and a half appear here.'),
          )
        else
          for (final r in sessions) _sessionTile(context, r),
      ],
    );
  }

  Widget _candidateTile(BuildContext context, ActivityCandidate c) {
    final monarchs = c.boxes.map((b) => b.monarch ?? 'unknown cypher').join(', ');
    return ListTile(
      leading: const Icon(Icons.markunread_mailbox_outlined, color: postalRed),
      title: Text('${c.boxes.length == 1 ? 'A postbox' : '${c.boxes.length} postboxes'} at ${clockTime(c.passedAtMs)}'),
      subtitle: Text('On your ${sessionNoun(c.exerciseType)} · ${c.totalPoints} pts · $monarchs'),
      trailing: FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
        onPressed: () => _openClaim(c),
        child: const Text('Claim'),
      ),
    );
  }

  Widget _sessionTile(BuildContext context, SessionRecord r) {
    final s = r.session;
    final subtitle = switch (r.verdict) {
      'ok' => r.passed == 0 && r.alreadyClaimed == 0
          ? 'No unclaimed postboxes on this route'
          : '${r.passed} to claim${r.alreadyClaimed > 0 ? ' · ${r.alreadyClaimed} already claimed' : ''}',
      _ => verdictLabel(r.verdict),
    };
    final needsConsent = r.verdict == 'consent_required' || r.verdict == 'denied';
    return ListTile(
      leading: Icon(switch (s.type) {
        'running' => Icons.directions_run,
        'hiking' => Icons.hiking,
        _ => Icons.directions_walk,
      }),
      title: Text('${sessionTitle(s)} · ${clockTime(s.startMs)}'),
      subtitle: Text('$subtitle · ${originLabel(s.originPackage)}'),
      trailing: needsConsent
          ? OutlinedButton(
              onPressed: _checking ? null : () => _checkWithConsent(s),
              child: const Text('Check'),
            )
          : null,
    );
  }
}
