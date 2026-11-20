import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/firebase_functions_eu.dart';
import 'package:postbox_game/james_controller.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/james_strip.dart';
import 'package:postbox_game/location_service.dart';
import 'package:postbox_game/streak_service.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/widgets/claim_quiz_sheet.dart';

import 'postbox_link_status.dart';

/// Matches [HttpsCallable.call] for `postboxLinkStatus`, so tests can stub it.
typedef PostboxLinkStatusFn = Future<HttpsCallableResult<dynamic>> Function(
    Map<String, dynamic>);

/// How long Rescan stays disabled after a check, so a nervous thumb can't
/// hammer the callable.
const Duration kPostboxLinkRescanCooldown = Duration(seconds: 10);

/// Opened from a postbox link (`/postbox/CODE`): tells the player about the
/// box and how near they are, and opens the claim sheet when they're there.
///
/// The server answers with a distance BAND, never the box's position or an
/// exact distance (the fuzzy-compass rule), and never says which way to go.
/// Claiming goes through the ordinary [ClaimQuizSheet], so the quiz, the
/// attempt id and the maintenance guard are exactly the Claim tab's. Like
/// every claim, it takes every unclaimed box in range, not only this one.
///
/// Pushed above the Home shell, so it owns its James controller and strip
/// (`JamesController.of` returns null outside Home's scope).
class PostboxLinkScreen extends StatefulWidget {
  const PostboxLinkScreen({
    super.key,
    required this.code,
    this.src,
    this.statusCallable,
    this.positionProvider,
    this.nearbyCallableForSheet,
    this.startScoringCallableForSheet,
    this.streakStream,
  });

  /// The link code from the URL (never the postbox's doc id).
  final String code;

  /// The link's `?src=` tag, for analytics only.
  final String? src;

  final PostboxLinkStatusFn? statusCallable;
  final Future<Position> Function()? positionProvider;
  final NearbyPostboxesCallableFn? nearbyCallableForSheet;
  final StartScoringCallableFn? startScoringCallableForSheet;
  final Stream<int?>? streakStream;

  @override
  State<PostboxLinkScreen> createState() => _PostboxLinkScreenState();
}

enum _Stage { loading, loaded, notFound, error }

class _PostboxLinkScreenState extends State<PostboxLinkScreen> {
  final JamesController _james = JamesController();
  late final PostboxLinkStatusFn _status = widget.statusCallable ??
      (payload) =>
          appFunctions.httpsCallable('postboxLinkStatus').call(payload);
  late final Stream<int?> _streakStream =
      widget.streakStream ?? StreakService().streakStream();

  _Stage _stage = _Stage.loading;
  PostboxLinkStatus? _result;
  Position? _position;
  LocationErrorKind? _locationError;
  bool _sheetOpen = false;
  bool _autoOpened = false;
  bool _claimed = false;
  bool _coolingDown = false;
  Timer? _cooldownTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _james.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _stage = _Stage.loading;
      _coolingDown = true;
    });
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer(kPostboxLinkRescanCooldown, () {
      if (mounted) setState(() => _coolingDown = false);
    });

    Position? position;
    LocationErrorKind? locationError;
    try {
      position = await (widget.positionProvider ?? getPosition)();
    } on LocationServiceException catch (e) {
      locationError = e.kind;
    } catch (_) {
      // A timeout or a platform hiccup: carry on without a position and
      // show what we can about the box.
    }
    if (!mounted) return;

    PostboxLinkStatus status;
    try {
      final result = await _status({
        'code': widget.code,
        if (position != null) 'lat': position.latitude,
        if (position != null) 'lng': position.longitude,
      });
      status = PostboxLinkStatus.fromCallable(result.data);
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      final notFound = e.code == 'invalid-argument' || e.code == 'not-found';
      _settle(notFound ? _Stage.notFound : _Stage.error, null, null, null);
      return;
    } catch (_) {
      if (!mounted) return;
      _settle(_Stage.error, null, null, null);
      return;
    }
    if (!mounted) return;
    if (!status.found) {
      _settle(_Stage.notFound, null, null, null);
      return;
    }
    _settle(_Stage.loaded, status, position, locationError);
  }

  void _settle(_Stage stage, PostboxLinkStatus? status, Position? position,
      LocationErrorKind? locationError) {
    setState(() {
      _stage = stage;
      _result = status;
      _position = position;
      _locationError = locationError;
    });
    switch (stage) {
      case _Stage.notFound:
        unawaited(Analytics.postboxLinkResult(result: 'not_found'));
        _james.show(JamesMessages.postboxLinkNotFound.resolve());
      case _Stage.error:
        unawaited(Analytics.postboxLinkResult(result: 'error'));
      case _Stage.loading:
        break;
      case _Stage.loaded:
        final proximity = status!.proximity;
        unawaited(Analytics.postboxLinkResult(result: proximity.analyticsName));
        final line = _jamesLineFor(proximity, status.info.county);
        if (line != null) _james.show(line);
        if (proximity == PostboxProximity.claimable &&
            !_autoOpened &&
            position != null) {
          // "Open the claim flow for this box": once per screen, so closing
          // the sheet doesn't reopen it on the next check.
          _autoOpened = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _openClaimSheet();
          });
        }
    }
  }

  String? _jamesLineFor(PostboxProximity proximity, String? county) =>
      switch (proximity) {
        PostboxProximity.claimable =>
          JamesMessages.postboxLinkClaimable.resolve(),
        PostboxProximity.veryClose =>
          JamesMessages.postboxLinkVeryClose.resolve(),
        PostboxProximity.shortWalk =>
          JamesMessages.postboxLinkShortWalk.resolve(),
        PostboxProximity.underKm => JamesMessages.postboxLinkUnderKm.resolve(),
        PostboxProximity.far => JamesMessages.postboxLinkFar(county),
        PostboxProximity.claimedToday =>
          JamesMessages.postboxLinkClaimedToday.resolve(),
        PostboxProximity.unknown =>
          JamesMessages.postboxLinkNoLocation.resolve(),
      };

  void _openClaimSheet() {
    final position = _position;
    if (_sheetOpen || position == null) return;
    _sheetOpen = true;
    showModalBottomSheet<ClaimQuizResult>(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        expand: false,
        builder: (_, __) => ClaimQuizSheet(
          scanPosition: LatLng(position.latitude, position.longitude),
          compact: true,
          streakStream: _streakStream,
          nearbyCallable: widget.nearbyCallableForSheet,
          startScoringCallable: widget.startScoringCallableForSheet,
          // Fires when the server commits the claim, even if the sheet is
          // then swiped away rather than completed.
          onClaimRecorded: _onClaimRecorded,
          onCompleted: (result) => Navigator.of(context).pop(result),
        ),
      ),
    ).then((_) {
      _sheetOpen = false;
    });
  }

  void _onClaimRecorded(ClaimQuizResult result) {
    if (!mounted || result.claimedCount <= 0) return;
    unawaited(Analytics.postboxLinkResult(result: 'claimed'));
    setState(() => _claimed = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Postbox')),
      body: Stack(
        children: [
          SafeArea(
            child: switch (_stage) {
              _Stage.loading => const Center(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: kJamesStripClearance),
                    child: CircularProgressIndicator(),
                  ),
                ),
              _Stage.notFound => _Message(
                  icon: Icons.markunread_mailbox_outlined,
                  title: "We can't find that postbox",
                  body: 'The link may be mistyped, or the postbox has been '
                      'taken off the map.',
                ),
              _Stage.error => _Message(
                  icon: Icons.cloud_off_outlined,
                  title: "Couldn't look that up",
                  body: 'Check your connection and try again.',
                  action: FilledButton(
                    onPressed: _check,
                    child: const Text('Try again'),
                  ),
                ),
              _Stage.loaded => _buildLoaded(context),
            },
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: JamesStrip(controller: _james),
          ),
        ],
      ),
    );
  }

  Widget _buildLoaded(BuildContext context) {
    final status = _result!;
    final info = status.info;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.md, AppSpacing.md, kJamesStripClearance),
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(info.headline, style: theme.textTheme.titleLarge),
                const SizedBox(height: AppSpacing.xs),
                Text(info.label,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: AppSpacing.md),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    Chip(
                      avatar: const Icon(Icons.star_outline, size: 18),
                      label: Text(info.points == 1
                          ? '1 point'
                          : '${info.points} points'),
                    ),
                    Chip(
                      avatar: const Icon(Icons.history, size: 18),
                      label: Text(info.claimsText),
                    ),
                    Chip(
                      avatar: const Icon(Icons.map_outlined, size: 18),
                      label: Text(info.county == null
                          ? 'Somewhere in the UK'
                          : 'Somewhere in ${info.county}'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (_claimed)
          _ProximityCard(
            icon: Icons.check_circle_outline,
            title: 'Claimed!',
            body: 'Nicely done. Come back tomorrow to claim it again.',
          )
        else
          _proximityCard(status.proximity, info.county),
        const SizedBox(height: AppSpacing.md),
        OutlinedButton.icon(
          onPressed: _coolingDown ? null : _check,
          icon: const Icon(Icons.my_location),
          label: const Text('Check again'),
        ),
      ],
    );
  }

  Widget _proximityCard(PostboxProximity proximity, String? county) {
    final claimButton = FilledButton.icon(
      onPressed: _sheetOpen ? null : _openClaimSheet,
      icon: const Icon(Icons.add_location_alt),
      label: Text(proximity == PostboxProximity.claimable
          ? 'Claim it'
          : 'Try to claim'),
    );
    return switch (proximity) {
      PostboxProximity.claimable => _ProximityCard(
          icon: Icons.where_to_vote_outlined,
          title: "You're there",
          body: 'Claiming takes every postbox within reach, so you may '
              'bag a bonus one.',
          action: claimButton,
        ),
      PostboxProximity.veryClose => _ProximityCard(
          icon: Icons.local_fire_department_outlined,
          title: 'Very close',
          body: "It's within about 100 metres. Have a look around, then try "
              'to claim it.',
          action: claimButton,
        ),
      PostboxProximity.shortWalk => const _ProximityCard(
          icon: Icons.directions_walk,
          title: 'A short walk away',
          body: "It's within about 300 metres. Which way is for you to find "
              'out.',
        ),
      PostboxProximity.underKm => const _ProximityCard(
          icon: Icons.hiking,
          title: 'Under a kilometre away',
          body: 'Close enough for a stroll. Get within 30 metres to claim it.',
        ),
      PostboxProximity.far => _ProximityCard(
          icon: Icons.ac_unit,
          title: 'More than a kilometre away',
          body: county == null
              ? 'Get within 30 metres of it to claim it.'
              : "It's somewhere in $county. Get within 30 metres of it to "
                  'claim it.',
        ),
      PostboxProximity.claimedToday => const _ProximityCard(
          icon: Icons.event_available_outlined,
          title: 'Claimed today',
          body: "You've already claimed this one today. Come back tomorrow.",
        ),
      PostboxProximity.unknown => _ProximityCard(
          icon: Icons.location_off_outlined,
          title: 'Where are you?',
          body: 'Turn on location to see how close you are.',
          action: switch (_locationError) {
            LocationErrorKind.servicesDisabled => const FilledButton(
                onPressed: Geolocator.openLocationSettings,
                child: Text('Open location settings'),
              ),
            LocationErrorKind.permissionPermanentlyDenied => const FilledButton(
                onPressed: Geolocator.openAppSettings,
                child: Text('Open settings'),
              ),
            _ => null,
          },
        ),
    };
  }
}

class _ProximityCard extends StatelessWidget {
  const _ProximityCard({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(body, style: theme.textTheme.bodyMedium),
            if (action != null) ...[
              const SizedBox(height: AppSpacing.md),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.xl, AppSpacing.lg, kJamesStripClearance),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(icon, size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: AppSpacing.md),
            Text(title,
                textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
            const SizedBox(height: AppSpacing.sm),
            Text(body,
                textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
            if (action != null) ...[
              const SizedBox(height: AppSpacing.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
