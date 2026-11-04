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

/// Hosting domain that serves the invite landing page and the App Links /
/// Universal Links verification files (`web/.well-known/`).
const String kInviteHost = 'the-postbox-game.web.app';

/// Custom scheme the invite page's "Open in the app" button uses. Distinct
/// from the widget's `postbox://` because iOS lets any app claim a scheme and
/// `postbox` is generic enough to collide.
const String kInviteScheme = 'postboxgame';

/// Crockford base32: no I, L, O or U. Must match `functions/src/invites.ts`
/// and the validation in `web/invite.html`.
final RegExp _inviteCodePattern = RegExp(r'^[0-9A-HJKMNP-TV-Z]{8}$');

/// Canonical form of a typed or pasted invite code, or null if [raw] isn't
/// one. Forgiving the way Crockford intends: case, spaces and hyphens are
/// ignored, and the look-alikes I/L read as 1 and O as 0. Mirrors the
/// server's `normaliseInviteCode`.
String? normaliseInviteCode(String? raw) {
  if (raw == null) return null;
  final code = raw
      .trim()
      .toUpperCase()
      .replaceAll(RegExp(r'[\s-]'), '')
      .replaceAll(RegExp('[IL]'), '1')
      .replaceAll('O', '0');
  return _inviteCodePattern.hasMatch(code) ? code : null;
}

/// The shareable invite link for [code].
String inviteUrlFor(String code) => 'https://$kInviteHost/invite/$code';

/// [code] split for reading aloud or typing: `ABCD-2345`.
String formatInviteCode(String code) => code.length == 8
    ? '${code.substring(0, 4)}-${code.substring(4)}'
    : code;

/// The invite code carried by [uri], or null when it isn't an invite link.
///
/// Accepts the https link (`https://the-postbox-game.web.app/invite/CODE`,
/// opened as an App Link / Universal Link) and the invite page's custom
/// scheme (`postboxgame://invite/CODE`). Everything else, including the
/// widget's `postbox://claim`, is not an invite: app_links sees every VIEW
/// intent, so this must stay strict.
String? parseInviteLink(Uri? uri) {
  if (uri == null) return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if ((uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host == kInviteHost &&
      segments.length == 2 &&
      segments[0] == 'invite') {
    return normaliseInviteCode(segments[1]);
  }
  if (uri.scheme == kInviteScheme &&
      uri.host == 'invite' &&
      segments.length == 1) {
    return normaliseInviteCode(segments[0]);
  }
  return null;
}

/// The invite code in what a player typed or pasted into the add-friend
/// field: a full invite link or a bare code. Null means "not an invite" (it
/// may still be a friend's UID).
String? parseInviteInput(String text) {
  final trimmed = text.trim();
  if (trimmed.contains('/')) {
    final withScheme = trimmed.contains('://') ? trimmed : 'https://$trimmed';
    return parseInviteLink(Uri.tryParse(withScheme));
  }
  return normaliseInviteCode(trimmed);
}

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
