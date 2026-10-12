import 'dart:async';
import 'dart:ui' as ui;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/deep_links.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/services/invite_service.dart';
import 'package:postbox_game/theme.dart';
import 'package:share_plus/share_plus.dart';

/// The landing page for shares made without an invite code.
const String kGetAppUrl = 'https://$kInviteHost/get';

/// What a share card shows. Deliberately no map, location, county or name:
/// a card is posted publicly, and the box a player claims most is often the
/// one on their own street.
class ShareCardData {
  const ShareCardData({
    required this.headline,
    this.cypher,
    this.points = 0,
    this.streak = 0,
    this.pointsText,
  });

  /// "I found a Victorian postbox!", "7-day streak!", ...
  final String headline;

  /// Monarch code for the badge, or null for a card without one.
  final String? cypher;
  final int points;
  final int streak;

  /// Replaces the default "+N points" line (e.g. a lifetime total).
  final String? pointsText;
}

/// Era phrase for a cypher, for "I found [a Victorian] postbox!".
String cypherPhrase(String cypher) => switch (cypher) {
      'VR' => 'a Victorian',
      'EVIIR' => 'an Edward VII',
      'EVIIIR' => 'an Edward VIII',
      'GR' || 'GVR' => 'a George V',
      'GVIR' => 'a George VI',
      'EIIR' => 'an Elizabeth II',
      'CIIIR' => 'a King Charles III',
      'SCOTTISH_CROWN' => 'a Scottish Crown',
      _ => 'a',
    };

/// Streak lengths that turn the claim card into a streak card.
const Set<int> kShareStreakMilestones = {7, 30, 100, 365};

/// [cypher] if it is a real royal cypher worth a badge, else null (unknown
/// codes and the "plain" bucket get a card without one).
String? shareableCypher(String? cypher) => (cypher != null &&
        cypher != MonarchInfo.plainKey &&
        MonarchInfo.labels.containsKey(cypher))
    ? cypher
    : null;

/// The card for a claim of [claimedCount] boxes worth [points]. [cypher] is
/// only meaningful for a single-box claim.
ShareCardData claimShareCard({
  required int claimedCount,
  required int points,
  String? cypher,
  int streak = 0,
}) {
  cypher = shareableCypher(cypher);
  if (claimedCount > 1 || cypher == null) {
    return ShareCardData(
      headline: claimedCount > 1
          ? 'I claimed $claimedCount postboxes!'
          : 'I claimed a postbox!',
      points: points,
      streak: streak,
    );
  }
  return ShareCardData(
    headline: 'I found ${cypherPhrase(cypher)} postbox!',
    cypher: cypher,
    points: points,
    streak: streak,
  );
}

/// The text that travels with the image. Always carries a link, so every
/// share is also an invite.
String buildShareText(ShareCardData data, String link) =>
    '${data.headline} Hunting royal postboxes on The Postbox Game. '
    'Play with me: $link';

/// Logical size of the card. Captured at 3x: 1080 x 1350, Instagram's 4:5
/// portrait, which every other network also displays uncropped.
const Size kShareCardSize = Size(360, 450);

/// The shareable card itself. Fixed-size and theme-independent so it looks
/// the same whatever mode the sharer's phone is in.
class ShareCard extends StatelessWidget {
  const ShareCard({super.key, required this.data, required this.link});

  final ShareCardData data;
  final String link;

  @override
  Widget build(BuildContext context) {
    final cypher = data.cypher;
    final badgeColour = cypher != null
        ? (MonarchInfo.colors[cypher] ?? postalGold)
        : postalGold;
    final display = GoogleFonts.playfairDisplay(
      color: Colors.white,
      fontSize: 30,
      fontWeight: FontWeight.w800,
      height: 1.1,
    );
    final body = GoogleFonts.plusJakartaSans(color: Colors.white);
    final shortLink = link.replaceFirst('https://', '');
    return SizedBox.fromSize(
      size: kShareCardSize,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [postalRed, Color(0xFF8B0A20)],
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              right: -12,
              bottom: 44,
              child: Image.asset(
                'assets/postman_james.png',
                height: 190,
                excludeFromSemantics: true,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    SvgPicture.asset(
                      'assets/postbox.svg',
                      height: 22,
                      colorFilter:
                          const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                      excludeFromSemantics: true,
                    ),
                    const SizedBox(width: 8),
                    Text('The Postbox Game',
                        style: body.copyWith(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                  ]),
                  const SizedBox(height: 28),
                  if (cypher != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: badgeColour,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: Text(
                        cypher == 'SCOTTISH_CROWN' ? 'Scottish Crown' : cypher,
                        style: body.copyWith(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: ThemeData.estimateBrightnessForColor(
                                      badgeColour) ==
                                  Brightness.dark
                              ? Colors.white
                              : royalNavy,
                        ),
                      ),
                    ),
                  if (cypher != null) const SizedBox(height: 14),
                  SizedBox(
                    width: 250,
                    child: Text(data.headline, style: display),
                  ),
                  if (cypher != null && MonarchInfo.labels[cypher] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(MonarchInfo.labels[cypher]!,
                          style: body.copyWith(
                              fontSize: 13,
                              color: Colors.white.withValues(alpha: 0.85))),
                    ),
                  const SizedBox(height: 18),
                  if (data.points > 0)
                    Text(data.pointsText ?? '+${data.points} points',
                        style: body.copyWith(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: postalGold)),
                  if (data.streak > 1)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('🔥 ${data.streak}-day streak',
                          style: body.copyWith(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                color: royalNavy,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Text(
                  'Play with me: $shortLink',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      body.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows a preview of the card with a Share button. [contentType] and
/// [itemId] label the analytics `share` event (`claim` / the cypher,
/// `streak` / the day count, `route`, `profile`).
Future<void> showShareCardSheet(
  BuildContext context, {
  required ShareCardData data,
  required String contentType,
  required String itemId,
}) async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  final code = uid == null ? null : await InviteService.myCode(uid);
  final link = code != null ? inviteUrlFor(code) : kGetAppUrl;
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ShareSheet(
      data: data,
      link: link,
      contentType: contentType,
      itemId: itemId,
    ),
  );
}

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({
    required this.data,
    required this.link,
    required this.contentType,
    required this.itemId,
  });

  final ShareCardData data;
  final String link;
  final String contentType;
  final String itemId;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  final GlobalKey _boundaryKey = GlobalKey();
  bool _sharing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Warm the artwork so the first capture isn't missing it.
    unawaited(
        precacheImage(const AssetImage('assets/postman_james.png'), context));
  }

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      // google_fonts loads at runtime: a capture taken before the font
      // arrives renders in the fallback face.
      await GoogleFonts.pendingFonts();
      await WidgetsBinding.instance.endOfFrame;
      final boundary = _boundaryKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 3);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (bytes == null) return;
      final result = await SharePlus.instance.share(ShareParams(
        files: [
          XFile.fromData(bytes.buffer.asUint8List(),
              mimeType: 'image/png', name: 'postbox-game.png'),
        ],
        fileNameOverrides: const ['postbox-game.png'],
        text: buildShareText(widget.data, widget.link),
      ));
      if (result.status != ShareResultStatus.dismissed) {
        unawaited(Analytics.share(
          contentType: widget.contentType,
          itemId: widget.itemId,
          method: result.raw.isNotEmpty ? result.raw : 'unknown',
        ));
      }
      if (mounted && result.status == ShareResultStatus.success) {
        Navigator.of(context).pop();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("Couldn't share that just now. Please try again.")));
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: FittedBox(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: RepaintBoundary(
                    key: _boundaryKey,
                    child: ShareCard(data: widget.data, link: widget.link),
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton.icon(
              onPressed: _sharing ? null : _share,
              icon: _sharing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.ios_share),
              label: const Text('Share'),
            ),
          ],
        ),
      ),
    );
  }
}
