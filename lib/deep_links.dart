import 'dart:async';

import 'package:flutter/material.dart';
import 'package:postbox_game/services/crashlytics_helper.dart';

/// The `source` values the app's own glanceable surfaces stamp on their claim
/// deep link. Each is a distinct entry point so analytics can tell them apart,
/// but they all mean "open the claim flow and scan".
///
/// Kotlin side: `PostboxWidgetProvider.kt` (widget) and, in the wear flavour,
/// `WearTileLaunchActivity.kt` (tile) / the complication tap actions. The
/// literals are pinned against this parser in `test/widget_test.dart`.
const Set<String> kClaimDeepLinkSources = <String>{
  'widget',
  'tile',
  'complication',
};

/// Whether [uri] is a claim deep link from any of the app's glanceable
/// surfaces (`postbox://claim?source=...`).
bool isClaimDeepLink(Uri? uri) =>
    uri != null &&
    uri.host == 'claim' &&
    kClaimDeepLinkSources.contains(uri.queryParameters['source']);

/// Whether [uri] is specifically the home-screen widget's claim deep link.
///
/// Kept separate from [isClaimDeepLink] because the phone consumes the widget
/// tap through `HomeWidget.widgetClicked`, which only ever reports the widget.
bool isWidgetClaimDeepLink(Uri? uri) =>
    uri != null &&
    uri.host == 'claim' &&
    uri.queryParameters['source'] == 'widget';

/// Counts home-screen-widget taps that should open Claim and auto-scan.
///
/// The app keys its Home on [epoch], so each bump remounts Home on the Claim
/// tab with a scan running. A tap asks for ONE scan: once a signed-in Home
/// has used it, signing out must drop it, or the next sign-in (possibly a
/// different account) would land on Claim and start a GPS scan unasked. A
/// tap made while signed out (including a cold start from the widget) still
/// carries through the login, which is what the tap asked for.
class WidgetAutoScanRequests {
  WidgetAutoScanRequests({bool launchedFromWidget = false})
      : _epoch = launchedFromWidget ? 1 : 0;

  int _epoch;
  bool _signedIn = false;

  /// 0 when no scan is pending; otherwise changes on every tap.
  int get epoch => _epoch;

  void tapped() => _epoch++;

  void signedIn() => _signedIn = true;

  void signedOut() {
    if (_signedIn) _epoch = 0;
    _signedIn = false;
  }

  String? _shownFor;

  /// The watch's variant of [signedIn]/[signedOut]. Its shell is shown signed
  /// out too (guest mode), so a tap is used the moment it's made and ANY
  /// later change of account (sign-in, sign-out, switch) drops it. [account]
  /// identifies who the shell is being built for.
  void shownFor(String account) {
    if (_shownFor != null && _shownFor != account) _epoch = 0;
    _shownFor = account;
  }
}

/// Whether [routeName] is the engine's named-route echo of one of the app's
/// own claim deep links: `postbox://claim?source=widget` has no path, so it
/// arrives as `/?source=widget`. See [unknownRoute].
bool isClaimDeepLinkEcho(String? routeName) {
  final uri = routeName == null ? null : Uri.tryParse(routeName);
  return uri != null &&
      !uri.hasScheme &&
      uri.path == '/' &&
      kClaimDeepLinkSources.contains(uri.queryParameters['source']);
}

/// Swallow a named route the app doesn't own, instead of crashing.
///
/// The platform pushes intent URIs into the Navigator as named routes
/// (`didPushRouteInformation` → `pushNamed`). The home-screen widget's
/// `postbox://claim?source=widget` arrives that way as `/?source=widget`,
/// which is in neither `routes` nor an `onGenerateRoute` — and with
/// `onUnknownRoute` unset Flutter does `widget.onUnknownRoute!(settings)`,
/// so tapping the widget WHILE THE APP WAS ALREADY OPEN hard-crashed it
/// (Crashlytics `_WidgetsAppState._onUnknownRoute`, fatal, 1.4.0).
///
/// Swallowing is the right answer rather than landing somewhere: the tap is
/// already handled properly by the surface's own listener, which opens the
/// claim flow and auto-scans. This route is the engine's duplicate of that
/// same tap. It must still return a real Route — returning null crashes on
/// the `_routeNamed(...)!` in `pushNamed` — so it returns a transparent one
/// that pops on the first frame.
///
/// Other unknown routes are still reported (non-fatally, deduped) so a
/// genuinely broken deep link doesn't just vanish. The claim-link echo is
/// not: it is expected on every tap made while the app is open, and logging
/// it buried any real broken link under a steady trickle of known noise.
Route<void> unknownRoute(RouteSettings settings) {
  if (!isClaimDeepLinkEcho(settings.name)) {
    unawaited(CrashlyticsHelper.recordHandled(
      StateError('unknown route pushed: ${settings.name}'),
      StackTrace.current,
      reason: 'navigator_unknown_route',
      dedupeKey: 'unknown_route_${settings.name}',
    ));
  }
  return PageRouteBuilder<void>(
    settings: settings,
    opaque: false,
    barrierColor: null,
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    pageBuilder: (_, __, ___) => const _SelfDismissingRoute(),
  );
}

/// Renders nothing and pops itself once mounted. See [unknownRoute].
class _SelfDismissingRoute extends StatefulWidget {
  const _SelfDismissingRoute();

  @override
  State<_SelfDismissingRoute> createState() => _SelfDismissingRouteState();
}

class _SelfDismissingRouteState extends State<_SelfDismissingRoute> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
