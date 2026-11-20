import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/deep_links.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/services/postbox_link_service.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/widgets/share_qr.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app's store landing page (web/get.html).
const String kGetAppUrl = 'https://$kInviteHost/get';

/// The link every share card carries, on the card and in the share text: the
/// landing page tagged `src=postbox_share`, which web/get.html passes to the
/// stores as the campaign, so installs from shares are attributed to them.
/// Generic rather than the sharer's invite link (until Nov 2026 it was the
/// invite link), so tapping a share doesn't add the sharer as a friend; the
/// two-way friend add stays with the Friends screen's invite.
const String kShareLinkUrl = '$kGetAppUrl?src=postbox_share';

/// A photo the player added to a share, with the aspect ratio it displays
/// at (after any EXIF rotation the decoder applies).
///
/// The bytes are only ever drawn into the card. They are never shared,
/// uploaded or written anywhere, because the original file can carry the
/// spot it was taken at in its EXIF GPS block. What leaves the phone is the
/// re-rendered card from [renderShareCardPng], which is pixels only.
@immutable
class SharePhoto {
  const SharePhoto({required this.bytes, required this.aspectRatio});

  final Uint8List bytes;

  /// Width over height.
  final double aspectRatio;

  /// Reads [bytes]' displayed aspect ratio, decoding a small thumbnail only.
  /// Throws if the bytes aren't an image the platform can decode.
  static Future<SharePhoto> decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 256);
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final ratio = image.width / image.height;
      image.dispose();
      return SharePhoto(bytes: bytes, aspectRatio: ratio);
    } finally {
      codec.dispose();
    }
  }
}

/// A postbox's link, drawn on a claim card as a QR code when the player
/// turns it on. Built from the box's opaque link code, never its doc id.
@immutable
class SharePostboxQr {
  const SharePostboxQr(this.code);

  final String code;

  /// What the QR encodes.
  String get qrUrl => postboxUrlFor(code, src: kPostboxSrcShareQr);

  /// The link in the share text.
  String get textUrl => postboxUrlFor(code, src: kPostboxSrcShareText);

  /// The link printed under the QR, for typing: no scheme, no tag.
  String get printedUrl => '$kInviteHost/postbox/$code';

  @override
  bool operator ==(Object other) =>
      other is SharePostboxQr && other.code == code;

  @override
  int get hashCode => code.hashCode;
}

/// What a share card shows. By default no map, location, county or name: a
/// card is posted publicly, and the box a player claims most is often the
/// one on their own street. Two things are the player's own choice, each
/// made after a privacy notice: a [photo] ([kSharePhotoPrivacyBody]; the card
/// is re-rendered from its pixels, so none of the file's metadata goes with
/// it), and a [qr] code linking to the postbox's page, which shows its county
/// and a circle about a kilometre across ([kPostboxLinkPrivacyBody]).
class ShareCardData {
  const ShareCardData({
    required this.headline,
    this.cypher,
    this.points = 0,
    this.streak = 0,
    this.pointsText,
    this.photo,
    this.clean = false,
    this.qr,
  });

  /// "I found a Victorian postbox!", "7-day streak!", ...
  final String headline;

  /// Monarch code for the badge, or null for a card without one.
  final String? cypher;
  final int points;
  final int streak;

  /// Replaces the default "+N points" line (e.g. a lifetime total).
  final String? pointsText;

  /// The player's photo, which then fills the card.
  final SharePhoto? photo;

  /// With a [photo]: drop the branding and link, leaving the photo and a
  /// small cypher caption. Ignored without a photo.
  final bool clean;

  /// The claimed postbox's link, shown as a QR code (claim cards only).
  final SharePostboxQr? qr;

  /// Whether the card draws [qr]: not on a clean photo, which has no strip.
  bool get showsQr => qr != null && !(photo != null && clean);

  ShareCardData copyWith({
    SharePhoto? photo,
    bool clearPhoto = false,
    bool? clean,
    SharePostboxQr? qr,
    bool clearQr = false,
  }) =>
      ShareCardData(
        headline: headline,
        cypher: cypher,
        points: points,
        streak: streak,
        pointsText: pointsText,
        photo: clearPhoto ? null : (photo ?? this.photo),
        clean: clean ?? this.clean,
        qr: clearQr ? null : (qr ?? this.qr),
      );

  /// The analytics `style` of a share made from this card.
  String get shareStyle =>
      photo == null ? 'card' : (clean ? 'photo_clean' : 'photo');
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

/// The text that travels with the image. Always carries a link, including
/// for a [ShareCardData.clean] photo: the postbox's own page when the card
/// shows its QR, otherwise [link].
String buildShareText(ShareCardData data, String link) => data.showsQr
    ? '${data.headline} Hunting royal postboxes on The Postbox Game. '
        'Can you find it? ${data.qr!.textUrl}'
    : '${data.headline} Hunting royal postboxes on The Postbox Game. '
        'Claim your postboxes: $link';

/// Logical size of the card. Captured at 3x: 1080 x 1350, Instagram's 4:5
/// portrait, which every other network also displays uncropped.
const Size kShareCardSize = Size(360, 450);

/// Maximum pinch zoom when framing a photo.
const double kSharePhotoMaxScale = 3;

// Privacy copy for photo shares. Shown before the first photo is picked
// (once per install) and as a reminder while a photo is attached.
const String kSharePhotoPrivacyTitle = "Careful what's in the picture";
const String kSharePhotoPrivacyBody =
    'Your photo will be public wherever you share it. House numbers, street '
    'signs, shop names and number plates can show where you live. A '
    'close-up of the cypher is safest.';
const String kSharePhotoReminder =
    "Check the photo doesn't show a house number, street sign or number plate.";

/// SharedPreferences key: the photo privacy notice has been acknowledged.
const String kSharePhotoPrivacyAckKey = 'share_photo_privacy_ack';

// Privacy copy for sharing a postbox's link (the claim card's QR code and the
// History "Share link" button), shown once per install before the first one.
const String kPostboxLinkPrivacyTitle = 'This shows roughly where the box is';
const String kPostboxLinkPrivacyBody =
    "Anyone with the link sees the postbox's county and a map circle about a "
    "kilometre across. If it's your home postbox, that's roughly where you "
    'live.';

/// SharedPreferences key: the postbox-link privacy notice has been
/// acknowledged.
const String kPostboxLinkPrivacyAckKey = 'postbox_link_privacy_ack';

/// Shows a privacy notice once per install (remembered under [prefsKey]).
/// True to carry on; false if the player backed out.
Future<bool> confirmOncePerInstall(
  BuildContext context, {
  required String prefsKey,
  required String title,
  required String body,
}) async {
  SharedPreferences? prefs;
  try {
    prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(prefsKey) ?? false) return true;
  } catch (_) {
    // Unreadable prefs: show the notice anyway.
  }
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.privacy_tip_outlined),
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: dialogActionStyle(),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Got it'),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  try {
    await prefs?.setBool(prefsKey, true);
  } catch (_) {
    // Not remembered: the notice shows again next time. Harmless.
  }
  return true;
}

/// The postbox-link notice ([kPostboxLinkPrivacyBody]).
Future<bool> confirmPostboxLinkPrivacy(BuildContext context) =>
    confirmOncePerInstall(
      context,
      prefsKey: kPostboxLinkPrivacyAckKey,
      title: kPostboxLinkPrivacyTitle,
      body: kPostboxLinkPrivacyBody,
    );

/// The size a photo of [aspectRatio] is drawn at so that it covers [frame]
/// (BoxFit.cover, without cropping it to the frame, so it can be panned).
Size coverSize(double aspectRatio, Size frame) =>
    aspectRatio > frame.aspectRatio
        ? Size(frame.height * aspectRatio, frame.height)
        : Size(frame.width, frame.width / aspectRatio);

/// Clamps a framing [offset] so a photo of [aspectRatio], zoomed by [scale]
/// about the frame's centre, still covers the whole [frame].
Offset clampPhotoOffset(
  Offset offset, {
  required double scale,
  required double aspectRatio,
  Size frame = kShareCardSize,
}) {
  final drawn = coverSize(aspectRatio, frame) * scale;
  final maxX = math.max(0.0, (drawn.width - frame.width) / 2);
  final maxY = math.max(0.0, (drawn.height - frame.height) / 2);
  return Offset(
    offset.dx.clamp(-maxX, maxX),
    offset.dy.clamp(-maxY, maxY),
  );
}

/// Renders [boundary] (a [ShareCard]) to the PNG that is shared: 3x, so
/// 1080 x 1350. Pixels only: no metadata from a player's photo survives.
Future<Uint8List?> renderShareCardPng(RenderRepaintBoundary boundary) async {
  final image = await boundary.toImage(pixelRatio: 3);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes?.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// The shareable card itself. Fixed-size and theme-independent so it looks
/// the same whatever mode the sharer's phone is in.
class ShareCard extends StatelessWidget {
  const ShareCard({
    super.key,
    required this.data,
    required this.link,
    this.photoScale = 1,
    this.photoOffset = Offset.zero,
  });

  final ShareCardData data;
  final String link;

  /// The player's framing of [ShareCardData.photo]: zoom about the centre,
  /// then a pan in logical pixels (see [clampPhotoOffset]).
  final double photoScale;
  final Offset photoOffset;

  static TextStyle get _body => GoogleFonts.plusJakartaSans(color: Colors.white);

  @override
  Widget build(BuildContext context) {
    final photo = data.photo;
    // Its own Material, so the card never inherits text decoration (or the
    // missing-Material debug underline) from wherever it is rendered.
    return SizedBox.fromSize(
      size: kShareCardSize,
      child: Material(
        type: MaterialType.transparency,
        child: ClipRect(
          child: photo == null ? _buildCard() : _buildPhotoCard(photo),
        ),
      ),
    );
  }

  String get _shortLink => link.replaceFirst('https://', '');

  Color get _badgeColour =>
      (data.cypher != null ? MonarchInfo.colors[data.cypher] : null) ??
      postalGold;

  static String _cypherText(String cypher) =>
      cypher == 'SCOTTISH_CROWN' ? 'Scottish Crown' : cypher;

  Widget _cypherPill(String cypher, {double fontSize = 18}) {
    final colour = _badgeColour;
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: fontSize * 0.75, vertical: fontSize / 3),
      decoration: BoxDecoration(
        color: colour,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Text(
        _cypherText(cypher),
        style: _body.copyWith(
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          color: ThemeData.estimateBrightnessForColor(colour) == Brightness.dark
              ? Colors.white
              : royalNavy,
        ),
      ),
    );
  }

  Widget _brand({double size = 15}) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SvgPicture.asset(
            'assets/postbox.svg',
            height: size * 1.45,
            colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
            excludeFromSemantics: true,
          ),
          SizedBox(width: size / 2),
          Text('The Postbox Game',
              style: _body.copyWith(
                  fontSize: size, fontWeight: FontWeight.w700)),
        ],
      );

  String? get _pointsLine => data.points > 0
      ? (data.pointsText ?? '+${data.points} points')
      : null;

  String? get _streakLine =>
      data.streak > 1 ? '🔥 ${data.streak}-day streak' : null;

  /// Logical size of the QR on the plain card: 100 px = 300 at the 3x
  /// capture, so about 7 px per module for a version-4 symbol.
  static const double _qrSize = 100;

  /// The plain card's bottom strip when it shows a QR code.
  static const double _qrStripHeight = _qrSize + 20;

  Widget _qrTile(SharePostboxQr qr, double size) => ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: ShareQr(data: qr.qrUrl, size: size),
      );

  Widget _qrStrip(SharePostboxQr qr) => Container(
        height: _qrStripHeight,
        width: double.infinity,
        color: royalNavy,
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            _qrTile(qr, _qrSize),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Scan to find this postbox',
                      maxLines: 2,
                      style: _body.copyWith(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          height: 1.15)),
                  const SizedBox(height: 6),
                  // Scaled to fit, never truncated: the link has to stay
                  // typeable.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      qr.printedUrl,
                      maxLines: 1,
                      style: _body.copyWith(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withValues(alpha: 0.85)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _brand(size: 11),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _linkStrip() => Container(
        width: double.infinity,
        color: royalNavy,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        // Scaled to fit, never truncated: the link has to stay typeable.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            'Claim your postboxes: $_shortLink',
            maxLines: 1,
            style: _body.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      );

  // ---------------------------------------------------------------------
  // Without a photo: a postmark-style stamp of the cypher on postal red.

  Widget _buildCard() {
    final cypher = data.cypher;
    final era = cypher != null ? MonarchInfo.labels[cypher] : null;
    final points = _pointsLine;
    final streak = _streakLine;
    final qr = data.showsQr ? data.qr : null;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [postalRed, Color(0xFF8B0A20)],
        ),
      ),
      child: Stack(
        children: [
          // The guide's art sits above the link strip; the taller QR strip
          // leaves no room for him.
          if (qr == null)
            Positioned(
              right: 6,
              bottom: 46,
              child: Image.asset(
                'assets/postman_james.png',
                height: 72,
                excludeFromSemantics: true,
              ),
            ),
          Positioned.fill(
            bottom: qr == null ? 42 : _qrStripHeight,
            child: Padding(
              padding: EdgeInsets.fromLTRB(24, qr == null ? 20 : 16, 24, 0),
              child: Column(
                children: [
                  Align(alignment: Alignment.centerLeft, child: _brand()),
                  SizedBox(height: qr == null ? 16 : 10),
                  _Postmark(
                    size: qr == null ? 128 : 96,
                    child: cypher != null
                        ? Text(
                            cypher == 'SCOTTISH_CROWN'
                                ? 'Scottish\nCrown'
                                : cypher,
                            textAlign: TextAlign.center,
                            style: GoogleFonts.playfairDisplay(
                              color: Colors.white,
                              fontSize: (cypher == 'SCOTTISH_CROWN'
                                      ? 20
                                      : (cypher.length > 4 ? 26 : 32)) *
                                  (qr == null ? 1 : 0.8),
                              fontWeight: FontWeight.w800,
                              height: 1.05,
                            ),
                          )
                        : SvgPicture.asset(
                            'assets/postbox.svg',
                            height: 56,
                            colorFilter: const ColorFilter.mode(
                                Colors.white, BlendMode.srcIn),
                            excludeFromSemantics: true,
                          ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    data.headline,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.playfairDisplay(
                      color: Colors.white,
                      fontSize: 25,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                    ),
                  ),
                  if (era != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(era,
                          style: _body.copyWith(
                              fontSize: 13,
                              color: Colors.white.withValues(alpha: 0.85))),
                    ),
                  const SizedBox(height: 10),
                  if (points != null)
                    Text(points,
                        style: _body.copyWith(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: postalGold)),
                  if (streak != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(streak,
                          style: _body.copyWith(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                    ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: qr == null ? _linkStrip() : _qrStrip(qr),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // With a photo: the photo is the hero, like an r/Postboxes post.

  Widget _buildPhotoCard(SharePhoto photo) {
    final drawn = coverSize(photo.aspectRatio, kShareCardSize);
    final cypher = data.cypher;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: royalNavy),
        Transform.translate(
          offset: photoOffset,
          child: Transform.scale(
            scale: photoScale,
            child: OverflowBox(
              minWidth: drawn.width,
              maxWidth: drawn.width,
              minHeight: drawn.height,
              maxHeight: drawn.height,
              child: Image.memory(
                photo.bytes,
                fit: BoxFit.fill,
                gaplessPlayback: true,
                excludeFromSemantics: true,
              ),
            ),
          ),
        ),
        if (data.clean && cypher != null)
          Positioned(left: 14, bottom: 14, child: _cleanCaption(cypher)),
        if (!data.clean) ...[
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 200,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00000000), Color(0x99000000)],
                ),
              ),
            ),
          ),
          Positioned(left: 0, right: 0, bottom: 0, child: _photoStrip()),
        ],
      ],
    );
  }

  Widget _cleanCaption(String cypher) {
    final era = MonarchInfo.labels[cypher];
    return Container(
      constraints: const BoxConstraints(maxWidth: 300),
      padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _cypherPill(cypher, fontSize: 13),
          if (era != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(era,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _body.copyWith(
                      fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          ],
        ],
      ),
    );
  }

  /// Logical size of the QR in the photo card's strip.
  static const double _photoQrSize = 84;

  Widget _photoStrip() {
    final qr = data.showsQr ? data.qr : null;
    final strip = _photoStripText();
    return Container(
      color: royalNavy.withValues(alpha: 0.9),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 9),
      child: qr == null
          ? strip
          : Row(
              children: [
                Expanded(child: strip),
                const SizedBox(width: 10),
                _qrTile(qr, _photoQrSize),
              ],
            ),
    );
  }

  Widget _photoStripText() {
    final cypher = data.cypher;
    final qr = data.showsQr ? data.qr : null;
    final title =
        (cypher != null ? MonarchInfo.labels[cypher] : null) ?? data.headline;
    final detail = [_pointsLine, _streakLine].whereType<String>().join('  ·  ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (cypher != null) ...[
              // "Scottish Crown" is long: scale down rather than overflow.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: _cypherPill(cypher, fontSize: 15)),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _body.copyWith(
                          fontSize: 14, fontWeight: FontWeight.w700)),
                  if (detail.isNotEmpty)
                    Text(detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _body.copyWith(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: postalGold)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        Row(
          children: [
            _brand(size: 11),
            const SizedBox(width: 10),
            Expanded(
              // Scaled to fit, never truncated: the link has to stay
              // typeable.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(
                  qr?.printedUrl ?? _shortLink,
                  maxLines: 1,
                  style: _body.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withValues(alpha: 0.85)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A round, double-ringed postmark around [child].
class _Postmark extends StatelessWidget {
  const _Postmark({required this.size, required this.child});

  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.08),
        border: Border.all(color: Colors.white, width: 3),
      ),
      padding: const EdgeInsets.all(5),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
              color: Colors.white.withValues(alpha: 0.7), width: 1.5),
        ),
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}

/// Picks a photo for a share, or null if the player backed out.
typedef SharePhotoPicker = Future<Uint8List?> Function(ImageSource source);

/// The real picker. `requestFullMetadata: false`: the share never needs the
/// photo's EXIF (and on iOS this avoids the full photo-library permission).
/// The bytes are drawn into the card and must never be shared directly, as
/// the original file can carry GPS coordinates.
Future<Uint8List?> pickSharePhoto(ImageSource source) async {
  final file = await ImagePicker().pickImage(
    source: source,
    maxWidth: 2160,
    imageQuality: 90,
    requestFullMetadata: false,
  );
  return file?.readAsBytes();
}

/// Shows a preview of the card with a Share button. [contentType] and
/// [itemId] label the analytics `share` event (`claim` / the cypher,
/// `streak` / the day count, `route`, `profile`).
///
/// [qrPostboxId] (claim shares only) offers an "Add postbox QR" switch for
/// that box. Without it, and with the switch off, the sheet makes no
/// Firebase calls; switching it on fetches the box's link code once.
Future<void> showShareCardSheet(
  BuildContext context, {
  required ShareCardData data,
  required String contentType,
  required String itemId,
  String? qrPostboxId,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ShareCardSheet(
        data: data,
        link: kShareLinkUrl,
        contentType: contentType,
        itemId: itemId,
        qrPostboxId: qrPostboxId,
      ),
    );

/// The share sheet's body: the card preview, the photo controls, the
/// optional postbox QR switch and the Share button. Public for tests, which
/// inject [pickPhoto] and [fetchLinkCode].
class ShareCardSheet extends StatefulWidget {
  const ShareCardSheet({
    super.key,
    required this.data,
    required this.link,
    required this.contentType,
    required this.itemId,
    this.pickPhoto = pickSharePhoto,
    this.qrPostboxId,
    this.fetchLinkCode = PostboxLinkService.fetchCode,
  });

  final ShareCardData data;
  final String link;
  final String contentType;
  final String itemId;
  final SharePhotoPicker pickPhoto;

  /// The claimed postbox the "Add postbox QR" switch would link to; null
  /// hides the switch.
  final String? qrPostboxId;
  final PostboxLinkFetcher fetchLinkCode;

  @override
  State<ShareCardSheet> createState() => _ShareCardSheetState();
}

class _ShareCardSheetState extends State<ShareCardSheet> {
  final GlobalKey _boundaryKey = GlobalKey();
  bool _sharing = false;
  bool _picking = false;
  bool _linking = false;
  bool _qrBusy = false;
  late ShareCardData _data = widget.data;

  double _scale = 1;
  Offset _offset = Offset.zero;
  double _gestureStartScale = 1;
  Offset _gestureStartOffset = Offset.zero;
  Offset _gestureStartFocal = Offset.zero;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Warm the artwork so the first capture isn't missing it.
    unawaited(
        precacheImage(const AssetImage('assets/postman_james.png'), context));
  }

  @override
  void dispose() {
    _evictPhoto(_data.photo);
    super.dispose();
  }

  /// Drops a photo's decoded pixels from the image cache, so nothing of it
  /// outlives the sheet.
  void _evictPhoto(SharePhoto? photo) {
    if (photo != null) unawaited(MemoryImage(photo.bytes).evict());
  }

  bool get _cameraAvailable =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// The once-per-install privacy notice. True to carry on to the picker.
  Future<bool> _confirmPhotoPrivacy() => confirmOncePerInstall(
        context,
        prefsKey: kSharePhotoPrivacyAckKey,
        title: kSharePhotoPrivacyTitle,
        body: kSharePhotoPrivacyBody,
      );

  /// The "Add postbox QR" switch. Turning it on shows the location notice
  /// (once per install) and fetches the box's link code.
  Future<void> _setQr(bool on) async {
    final postboxId = widget.qrPostboxId;
    if (postboxId == null || _qrBusy) return;
    if (!on) {
      setState(() => _data = _data.copyWith(clearQr: true));
      return;
    }
    _qrBusy = true;
    try {
      if (!await confirmPostboxLinkPrivacy(context) || !mounted) return;
      // The spinner shows only while fetching, not behind the notice.
      setState(() => _linking = true);
      final String code;
      try {
        code = await widget.fetchLinkCode(postboxId);
      } catch (_) {
        _snack("Couldn't make a link just now. Check your connection and "
            'try again.');
        return;
      }
      if (!mounted) return;
      setState(() => _data = _data.copyWith(qr: SharePostboxQr(code)));
    } finally {
      _qrBusy = false;
      if (mounted && _linking) setState(() => _linking = false);
    }
  }

  Future<ImageSource?> _chooseSource() => showModalBottomSheet<ImageSource>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Take a photo'),
                onTap: () => Navigator.of(context).pop(ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Choose from library'),
                onTap: () => Navigator.of(context).pop(ImageSource.gallery),
              ),
            ],
          ),
        ),
      );

  Future<void> _addPhoto() async {
    if (_picking || _sharing) return;
    setState(() => _picking = true);
    try {
      if (!await _confirmPhotoPrivacy() || !mounted) return;
      final source =
          _cameraAvailable ? await _chooseSource() : ImageSource.gallery;
      if (source == null || !mounted) return;
      final Uint8List? bytes;
      try {
        bytes = await widget.pickPhoto(source);
      } on PlatformException {
        _snack("Couldn't open the camera or your photos. Check the app's "
            'permissions in Settings.');
        return;
      }
      if (bytes == null || !mounted) return;
      final SharePhoto photo;
      try {
        photo = await SharePhoto.decode(bytes);
        if (!mounted) return;
        await precacheImage(MemoryImage(bytes), context);
      } catch (_) {
        _snack("Couldn't read that photo. Please try another.");
        return;
      }
      if (!mounted) return;
      final previous = _data.photo;
      setState(() {
        _data = _data.copyWith(photo: photo);
        _scale = 1;
        _offset = Offset.zero;
      });
      _evictPhoto(previous);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _removePhoto() {
    final previous = _data.photo;
    setState(() {
      _data = _data.copyWith(clearPhoto: true, clean: false);
      _scale = 1;
      _offset = Offset.zero;
    });
    _evictPhoto(previous);
  }

  void _onScaleStart(ScaleStartDetails d) {
    _gestureStartScale = _scale;
    _gestureStartOffset = _offset;
    _gestureStartFocal = d.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final photo = _data.photo;
    if (photo == null) return;
    // The detector sits inside the FittedBox, so local positions are in the
    // card's own logical pixels and a drag moves the photo 1:1.
    final scale =
        (_gestureStartScale * d.scale).clamp(1.0, kSharePhotoMaxScale);
    final offset = clampPhotoOffset(
      _gestureStartOffset + (d.localFocalPoint - _gestureStartFocal),
      scale: scale,
      aspectRatio: photo.aspectRatio,
    );
    setState(() {
      _scale = scale;
      _offset = offset;
    });
  }

  Future<void> _share() async {
    if (_sharing || _picking || _linking) return;
    setState(() => _sharing = true);
    try {
      // google_fonts loads at runtime: a capture taken before the font
      // arrives renders in the fallback face.
      await GoogleFonts.pendingFonts();
      await WidgetsBinding.instance.endOfFrame;
      final boundary = _boundaryKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return;
      // Only the re-rendered card is shared, never the photo's own file.
      final png = await renderShareCardPng(boundary);
      if (png == null) return;
      final result = await SharePlus.instance.share(ShareParams(
        files: [
          XFile.fromData(png, mimeType: 'image/png', name: 'postbox-game.png'),
        ],
        fileNameOverrides: const ['postbox-game.png'],
        text: buildShareText(_data, widget.link),
      ));
      if (result.status != ShareResultStatus.dismissed) {
        unawaited(Analytics.share(
          contentType: widget.contentType,
          itemId: widget.itemId,
          method: result.raw.isNotEmpty ? result.raw : 'unknown',
          style: _data.shareStyle,
          qr: widget.qrPostboxId == null ? null : _data.showsQr,
        ));
      }
      if (mounted && result.status == ShareResultStatus.success) {
        Navigator.of(context).pop();
      }
    } catch (_) {
      _snack("Couldn't share that just now. Please try again.");
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasPhoto = _data.photo != null;
    final hint = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
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
                  child: GestureDetector(
                    onScaleStart: hasPhoto ? _onScaleStart : null,
                    onScaleUpdate: hasPhoto ? _onScaleUpdate : null,
                    child: RepaintBoundary(
                      key: _boundaryKey,
                      child: ShareCard(
                        data: _data,
                        link: widget.link,
                        photoScale: _scale,
                        photoOffset: _offset,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (hasPhoto) ...[
              const SizedBox(height: AppSpacing.xs),
              Text('Pinch and drag to frame', style: hint),
              const SizedBox(height: AppSpacing.xs),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline,
                      size: 16, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(child: Text(kSharePhotoReminder, style: hint)),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Hide branding'),
                subtitle: const Text('The link still goes in the message'),
                value: _data.clean,
                onChanged: _sharing
                    ? null
                    : (v) => setState(() => _data = _data.copyWith(clean: v)),
              ),
            ] else
              const SizedBox(height: AppSpacing.sm),
            if (widget.qrPostboxId != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: _linking
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.qr_code_2),
                title: const Text('Add postbox QR'),
                subtitle: Text(hasPhoto && _data.clean
                    ? 'Not shown while branding is hidden'
                    : 'Links to this postbox, so others can hunt it down'),
                value: _data.qr != null,
                onChanged: _sharing ||
                        _picking ||
                        _linking ||
                        (hasPhoto && _data.clean)
                    ? null
                    : _setQr,
              ),
            // Expanded, not bare: the app theme gives filled and outlined
            // buttons an infinite minimum width, which a Row can't bound, so
            // unwrapped they fail layout and the whole row vanishes.
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        _picking || _sharing || _linking ? null : _addPhoto,
                    icon: const Icon(Icons.add_a_photo_outlined),
                    label: Text(hasPhoto ? 'Change photo' : 'Add photo'),
                  ),
                ),
                if (hasPhoto)
                  IconButton(
                    tooltip: 'Remove photo',
                    onPressed: _sharing ? null : _removePhoto,
                    icon: const Icon(Icons.close),
                  ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _sharing || _picking || _linking ? null : _share,
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
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
