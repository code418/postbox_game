import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:postbox_game/firebase_functions_eu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' show MapController;
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/app_preferences.dart' show ViewMode;
import 'package:postbox_game/james_controller.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/location_service.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/reports/report_cypher_screen.dart';
import 'package:postbox_game/services/claim_events.dart';
import 'package:postbox_game/services/crashlytics_helper.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/widgets/postbox_map.dart';
import 'package:postbox_game/widgets/postbox_marker.dart';
import 'package:postbox_game/widgets/view_toggle.dart';

/// Signature of the `userClaimHistory` callable, injectable for tests.
typedef ClaimHistoryCallableFn = Future<HttpsCallableResult<dynamic>> Function(
    Map<String, dynamic> payload);

/// A per-period view of the signed-in user's past claims, as either a map of
/// deduped postbox pins or a scrollable list. Tapping a pin/row opens a detail
/// sheet (times claimed, dates, points) with a "report wrong cypher" action.
///
/// The four tabs — Today, This week, This month, Lifetime — call the
/// `userClaimHistory` Cloud Function, which joins each claim against its
/// `postbox/{id}` document server-side so the client gets geopoints directly.
///
/// The map view carries a "My location" control that fetches a one-off GPS fix,
/// recentres the camera on it and draws the standard user dot.
class ClaimHistoryScreen extends StatefulWidget {
  const ClaimHistoryScreen({
    super.key,
    this.historyCallable,
    this.positionProvider,
  });

  /// Injectable stand-in for the `userClaimHistory` callable. Null uses the
  /// real one. Tests inject a stub so the map view renders without Firebase
  /// (mirrors `ClaimQuizSheet.nearbyCallable`).
  @visibleForTesting
  final ClaimHistoryCallableFn? historyCallable;

  /// Injectable provider for the "my location" fix. Null uses [getPosition].
  /// Tests must inject: geolocator has no MethodChannel mock in `test/`, so an
  /// unguarded call throws MissingPluginException.
  @visibleForTesting
  final Future<Position> Function()? positionProvider;

  @override
  State<ClaimHistoryScreen> createState() => _ClaimHistoryScreenState();
}

class _ClaimHistoryScreenState extends State<ClaimHistoryScreen>
    with SingleTickerProviderStateMixin {
  static const List<String> _periods = [
    'daily',
    'weekly',
    'monthly',
    'lifetime'
  ];
  static const Map<String, String> _labels = {
    'daily': 'Today',
    'weekly': 'This week',
    'monthly': 'This month',
    'lifetime': 'Lifetime',
  };
  late final TabController _tabController;
  // Default to the map view: the History screen's killer feature is seeing
  // where you've been; the list is the supporting detail view.
  ViewMode _view = ViewMode.map;

  late final ClaimHistoryCallableFn _historyCallable;
  late final Future<Position> Function() _positionProvider;

  /// The user's last known position, shared by all four period tabs so that
  /// locating on "Today" also shows the dot on "This week". Held here rather
  /// than inside `_HistoryMap` because a refresh swaps `_future`, which flips
  /// the FutureBuilder back to `waiting` and unmounts the map entirely — any
  /// position stored down there would silently vanish on every claim.
  LatLng? _userPosition;

  /// In-flight locate, so a second tap (or a tap on another tab) joins the
  /// existing fix instead of firing a second GPS read and permission prompt.
  Future<LatLng?>? _locateInFlight;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _periods.length, vsync: this);
    _historyCallable = widget.historyCallable ??
        ((payload) =>
            appFunctions.httpsCallable('userClaimHistory').call(payload));
    _positionProvider = widget.positionProvider ?? getPosition;
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<LatLng?> _locateUser() {
    final inFlight = _locateInFlight;
    if (inFlight != null) return inFlight;
    final future = _acquireUserPosition();
    _locateInFlight = future;
    future.whenComplete(() => _locateInFlight = null);
    return future;
  }

  /// Fetches a fix and records it. Never throws: every failure path explains
  /// itself to the user and returns null, so the map just skips the move.
  Future<LatLng?> _acquireUserPosition() async {
    try {
      final pos = await _positionProvider();
      if (!mounted) return null;
      final target = LatLng(pos.latitude, pos.longitude);
      setState(() => _userPosition = target);
      return target;
    } on LocationServiceException catch (e) {
      // Fire before the mounted check: the signal matters even if the user
      // has navigated away.
      if (e.kind == LocationErrorKind.permissionPermanentlyDenied) {
        unawaited(Analytics.locationPermissionPermanentlyDenied());
      }
      if (!mounted) return null;
      final isPermission = e.kind == LocationErrorKind.permissionDenied ||
          e.kind == LocationErrorKind.permissionPermanentlyDenied;
      JamesController.of(context)?.show(isPermission
          ? JamesMessages.nearbyErrorPermission.resolve()
          : JamesMessages.nearbyErrorGeneral.resolve());
      SnackBarAction? action;
      switch (e.kind) {
        case LocationErrorKind.permissionPermanentlyDenied:
          action = SnackBarAction(
            label: 'Open Settings',
            textColor: Colors.white,
            onPressed: Geolocator.openAppSettings,
          );
        case LocationErrorKind.servicesDisabled:
          action = SnackBarAction(
            label: 'Open Settings',
            textColor: Colors.white,
            onPressed: Geolocator.openLocationSettings,
          );
        case LocationErrorKind.permissionDenied:
          action = null;
      }
      // e.message, never e.toString(): the kind is the contract, the message
      // is the human-readable half of it.
      _showLocationError(e.message, action: action);
      return null;
    } on TimeoutException {
      // getPosition only rethrows this when getLastKnownPosition had nothing
      // either, i.e. there is genuinely no fix to be had.
      if (!mounted) return null;
      JamesController.of(context)?.show(JamesMessages.nearbyErrorGeneral.resolve());
      _showLocationError(
          'GPS signal timed out. Move to an open area and try again.');
      return null;
    } catch (_) {
      // Never surface a raw PlatformException string to the player.
      if (!mounted) return null;
      JamesController.of(context)?.show(JamesMessages.nearbyErrorGeneral.resolve());
      _showLocationError(
          'Could not determine your location. Please try again.');
      return null;
    }
  }

  void _showLocationError(String message, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: Colors.red.shade700,
      action: action,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          color: Theme.of(context).colorScheme.surface,
          width: double.infinity,
          // Full-width TabBar — the List/Map toggle moved to its own row below
          // so the period tabs no longer have to fight it for horizontal space.
          child: TabBar(
            controller: _tabController,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: _periods.map((p) => Tab(text: _labels[p])).toList(),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.xs),
          child: ViewToggle(
            mode: _view,
            expand: true,
            onChanged: (m) => setState(() => _view = m),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: _periods
                .map((p) => _HistoryTab(
                      key: ValueKey('history_$p'),
                      period: p,
                      view: _view,
                      callable: _historyCallable,
                      userPosition: _userPosition,
                      onLocateMe: _locateUser,
                    ))
                .toList(),
          ),
        ),
      ],
    );
  }
}

/// One tab per period. Kept alive by [AutomaticKeepAliveClientMixin] so swiping
/// between tabs doesn't refetch on every change.
class _HistoryTab extends StatefulWidget {
  const _HistoryTab({
    super.key,
    required this.period,
    required this.view,
    required this.callable,
    required this.userPosition,
    required this.onLocateMe,
  });
  final String period;
  final ViewMode view;
  final ClaimHistoryCallableFn callable;

  /// Shared across tabs; null until the user has located themselves once.
  final LatLng? userPosition;

  /// Returns the fix, or null when it could not be obtained (the screen has
  /// already told the user why).
  final Future<LatLng?> Function() onLocateMe;

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab>
    with AutomaticKeepAliveClientMixin {
  late Future<List<ClaimHistoryEntry>> _future;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
    // These tabs are keep-alive inside Home's IndexedStack, so initState runs
    // once at app start and the result sticks. Without this listener a claim
    // made after launch never appears until the user pulls to refresh — the
    // empty state actively told them "No claims today" seconds after claiming.
    ClaimEvents.revision.addListener(_onClaimRecorded);
  }

  @override
  void dispose() {
    ClaimEvents.revision.removeListener(_onClaimRecorded);
    super.dispose();
  }

  /// All four period tabs refetch on a claim. That is four cheap reads per
  /// claim, which is the right trade against any of them showing a stale
  /// answer: claims are infrequent, and there is no reliable way for an
  /// offstage IndexedStack child to know whether it is the visible one.
  void _onClaimRecorded() {
    if (!mounted) return;
    setState(() {
      _future = _fetch();
    });
  }

  Future<List<ClaimHistoryEntry>> _fetch() async {
    // Read-only: safe to retry wholesale, and a failure here empties the
    // whole history view rather than degrading it.
    final result = await retryOnUnavailable(
        () => widget.callable(<String, dynamic>{'period': widget.period}));
    final data = Map<String, dynamic>.from(result.data as Map);
    final raw = data['entries'] as List<dynamic>? ?? const [];
    return raw
        .map((e) =>
            ClaimHistoryEntry.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> _refresh() async {
    setState(() {
      _future = _fetch();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<List<ClaimHistoryEntry>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.only(bottom: kJamesStripClearance),
            child: Center(child: CircularProgressIndicator(color: postalRed)),
          );
        }
        if (snap.hasError) {
          return _ErrorState(onRetry: _refresh);
        }
        final entries = snap.data ?? const [];
        if (entries.isEmpty) {
          return _EmptyState(period: widget.period, onRefresh: _refresh);
        }
        return widget.view == ViewMode.list
            ? _HistoryList(
                entries: entries,
                onRefresh: _refresh,
                onTap: (e) => _showEntryDetails(context, e))
            : _HistoryMap(
                entries: entries,
                onRefresh: _refresh,
                onTap: (e) => _showEntryDetails(context, e),
                userPosition: widget.userPosition,
                onLocateMe: widget.onLocateMe,
              );
      },
    );
  }

  void _showEntryDetails(BuildContext context, ClaimHistoryEntry entry) {
    // Crash context: which claimed box (id only) and cypher the user is viewing.
    CrashlyticsHelper.setContext(
        CrashlyticsHelper.keyLastClaimId, entry.postboxId);
    if (entry.monarch != null) {
      CrashlyticsHelper.setContext(
          CrashlyticsHelper.keyLastMonarch, entry.monarch!);
    }
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => _EntryDetailSheet(entry: entry),
    );
  }
}

/// Zoom applied by "My location". PostboxMap hard-caps at 17 because OSM
/// renders postbox POI icons at zoom >= 18, which would reveal exact postbox
/// locations. 16 deliberately stops one step short: close enough to read the
/// street you are standing on, while leaving pinch-in headroom under the cap.
const double _kLocateZoom = 16.0;

class _HistoryMap extends StatefulWidget {
  const _HistoryMap({
    required this.entries,
    required this.onRefresh,
    required this.onTap,
    required this.userPosition,
    required this.onLocateMe,
  });
  final List<ClaimHistoryEntry> entries;
  final Future<void> Function() onRefresh;
  final void Function(ClaimHistoryEntry) onTap;
  final LatLng? userPosition;
  final Future<LatLng?> Function() onLocateMe;

  @override
  State<_HistoryMap> createState() => _HistoryMapState();
}

class _HistoryMapState extends State<_HistoryMap> {
  // A caller-supplied controller is the CALLER's to dispose: PostboxMap.dispose
  // only disposes the internal fallback it creates when mapController is null.
  final MapController _mapController = MapController();
  bool _locating = false;

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _locateMe() async {
    setState(() => _locating = true);
    try {
      final target = await widget.onLocateMe();
      // null means the screen has already surfaced the reason; stay put.
      if (!mounted || target == null) return;
      _mapController.move(target, _kLocateZoom);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final points = widget.entries.map((e) => LatLng(e.lat, e.lng)).toList();
    final user = widget.userPosition;
    return Stack(
      children: [
        PostboxMap(
          mapController: _mapController,
          // _centroid is a pure fold over `entries`, so an unchanged claim set
          // yields a bit-identical LatLng and PostboxMap.didUpdateWidget does
          // NOT schedule a camera move over the top of a "My location" move.
          // Keep this free of anything that varies per build.
          center: _centroid(points),
          zoom: _zoomForSpan(points),
          markers: [
            ...widget.entries.map((e) => postboxMarker(LatLng(e.lat, e.lng),
                cipher: e.monarch, onTap: () => widget.onTap(e))),
            // Last, so the dot paints above the postbox pins.
            if (user != null) userPositionMarker(user),
          ],
        ),
        // Map controls. Top-right rather than the usual bottom-right corner:
        // PostboxMap puts the required OSM attribution there, and covering it
        // is not an option.
        Positioned(
          top: AppSpacing.sm,
          right: AppSpacing.sm,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Keep-alive tabs fetch once in initState, so without this the
              // map would show stale data until app restart after a claim.
              _MapOverlayButton(
                tooltip: 'Refresh',
                onPressed: widget.onRefresh,
                child: const Icon(Icons.refresh, color: postalRed),
              ),
              const SizedBox(height: AppSpacing.sm),
              _MapOverlayButton(
                tooltip: 'My location',
                onPressed: _locating ? null : _locateMe,
                child: _locating
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: postalRed),
                      )
                    : const Icon(Icons.my_location, color: postalRed),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Circular translucent control floated over the map. Shared so the Refresh
/// and My-location buttons cannot drift apart visually.
class _MapOverlayButton extends StatelessWidget {
  const _MapOverlayButton({
    required this.tooltip,
    required this.onPressed,
    required this.child,
  });
  final String tooltip;
  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
      shape: const CircleBorder(),
      elevation: 2,
      child: IconButton(
        icon: child,
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }
}

class _HistoryList extends StatelessWidget {
  const _HistoryList(
      {required this.entries, required this.onRefresh, required this.onTap});
  final List<ClaimHistoryEntry> entries;
  final Future<void> Function() onRefresh;
  final void Function(ClaimHistoryEntry) onTap;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: postalRed,
      onRefresh: onRefresh,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, AppSpacing.md, AppSpacing.md, kJamesStripClearance),
        itemCount: entries.length,
        separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
        itemBuilder: (_, i) {
          final e = entries[i];
          final label = e.monarch != null
              ? (MonarchInfo.labels[e.monarch!] ?? e.monarch!)
              : 'No cypher recorded';
          final color =
              (e.monarch != null ? MonarchInfo.colors[e.monarch!] : null) ??
                  postalRed;
          return Card(
            child: ListTile(
              leading: CircleAvatar(
                  backgroundColor: color,
                  child: const Icon(Icons.markunread_mailbox,
                      color: Colors.white, size: 20)),
              title: Text(label),
              subtitle: Text(
                '${e.timesClaimed == 1 ? 'Claimed once' : 'Claimed ${e.timesClaimed} times'}'
                ' · ${e.totalPoints} pt${e.totalPoints == 1 ? '' : 's'}'
                '${e.reference != null && e.reference!.isNotEmpty ? ' · Ref ${e.reference}' : ''}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onTap(e),
            ),
          );
        },
      ),
    );
  }
}

LatLng _centroid(List<LatLng> points) {
  if (points.isEmpty) return const LatLng(54.5, -2.5);
  double sumLat = 0, sumLng = 0;
  for (final p in points) {
    sumLat += p.latitude;
    sumLng += p.longitude;
  }
  return LatLng(sumLat / points.length, sumLng / points.length);
}

double _zoomForSpan(List<LatLng> points) {
  if (points.length <= 1) return 15;
  double minLat = points.first.latitude, maxLat = minLat;
  double minLng = points.first.longitude, maxLng = minLng;
  for (final p in points) {
    minLat = math.min(minLat, p.latitude);
    maxLat = math.max(maxLat, p.latitude);
    minLng = math.min(minLng, p.longitude);
    maxLng = math.max(maxLng, p.longitude);
  }
  final delta = math.max(maxLat - minLat, maxLng - minLng);
  if (delta < 0.01) return 15;
  if (delta < 0.05) return 13;
  if (delta < 0.2) return 11;
  if (delta < 1.0) return 9;
  if (delta < 5.0) return 7;
  return 5;
}

/// Formats a server `YYYY-MM-DD` claim date as a human-friendly "20 May 2026".
/// Falls back to the raw string when empty or unparseable so a malformed date
/// never blanks out the detail sheet.
String _fmtClaimDate(String ymd) {
  if (ymd.isEmpty) return ymd;
  try {
    return DateFormat('d MMM yyyy').format(DateTime.parse(ymd));
  } catch (_) {
    return ymd;
  }
}

class ClaimHistoryEntry {
  const ClaimHistoryEntry({
    required this.postboxId,
    required this.lat,
    required this.lng,
    this.monarch,
    this.reference,
    required this.timesClaimed,
    required this.firstClaimed,
    required this.lastClaimed,
    required this.totalPoints,
  });

  final String postboxId;
  final double lat;
  final double lng;
  final String? monarch;
  final String? reference;
  final int timesClaimed;
  final String firstClaimed;
  final String lastClaimed;
  final int totalPoints;

  factory ClaimHistoryEntry.fromJson(Map<String, dynamic> json) {
    return ClaimHistoryEntry(
      postboxId: json['postboxId'] as String? ?? '',
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      monarch: json['monarch'] as String?,
      reference: json['reference'] as String?,
      timesClaimed: (json['timesClaimed'] as num?)?.toInt() ?? 1,
      firstClaimed: json['firstClaimed'] as String? ?? '',
      lastClaimed: json['lastClaimed'] as String? ?? '',
      totalPoints: (json['totalPoints'] as num?)?.toInt() ?? 0,
    );
  }
}

class _EntryDetailSheet extends StatelessWidget {
  const _EntryDetailSheet({required this.entry});
  final ClaimHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final monarchLabel = entry.monarch != null
        ? (MonarchInfo.labels[entry.monarch!] ?? entry.monarch!)
        : 'No cypher recorded';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: AppSpacing.md),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(monarchLabel,
                style: textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            if (entry.reference != null && entry.reference!.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Text('Ref ${entry.reference}',
                  style: textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  )),
            ],
            const SizedBox(height: AppSpacing.md),
            _DetailRow(
              icon: Icons.calendar_today_outlined,
              label: entry.firstClaimed == entry.lastClaimed
                  ? 'Claimed on ${_fmtClaimDate(entry.firstClaimed)}'
                  : 'First claimed ${_fmtClaimDate(entry.firstClaimed)} · last ${_fmtClaimDate(entry.lastClaimed)}',
            ),
            const SizedBox(height: AppSpacing.sm),
            _DetailRow(
              icon: Icons.repeat,
              label: entry.timesClaimed == 1
                  ? 'Claimed 1 time'
                  : 'Claimed ${entry.timesClaimed} times',
            ),
            const SizedBox(height: AppSpacing.sm),
            _DetailRow(
              icon: Icons.stars_outlined,
              label: entry.totalPoints == 1
                  ? '1 point earned'
                  : '${entry.totalPoints} points earned',
            ),
            if (!RemoteConfigService.instance.killSwitchReporting) ...[
              const SizedBox(height: AppSpacing.md),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => ReportCypherScreen(
                        postboxId: entry.postboxId,
                        currentMonarch: entry.monarch,
                        reference: entry.reference,
                      ),
                    ));
                  },
                  icon: const Icon(Icons.flag_outlined),
                  label: Text(entry.monarch == null
                      ? 'Report missing cypher'
                      : 'Report wrong cypher'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon,
            size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyLarge)),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.period, required this.onRefresh});
  final String period;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    const Map<String, String> empty = {
      'daily': 'No claims today — yet. Go find a postbox!',
      'weekly': 'No claims this week. Head out and start your tally.',
      'monthly': 'No claims this month. Time for a wander.',
      'lifetime': 'No claims yet. Your map is waiting to be filled.',
    };
    // Wrap in RefreshIndicator so users can pull to refresh after claiming —
    // the keep-alive tab state won't otherwise pick up new claims until the
    // screen is rebuilt.
    return RefreshIndicator(
      color: postalRed,
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(
            top: AppSpacing.xxl, bottom: kJamesStripClearance),
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.map_outlined,
                    size: 72,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.2)),
                const SizedBox(height: AppSpacing.md),
                Text('Nothing here yet',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        )),
                const SizedBox(height: AppSpacing.xs),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
                  child: Text(
                    empty[period] ?? empty['lifetime']!,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: kJamesStripClearance),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline,
                size: 48,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: AppSpacing.md),
            Text('Could not load history',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            TextButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
