import 'dart:async';

import 'package:flutter/material.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/deep_links.dart';
import 'package:postbox_game/services/postbox_link_service.dart';
import 'package:postbox_game/widgets/share_card.dart';
import 'package:share_plus/share_plus.dart';

/// Shares through the platform sheet; injectable for tests.
typedef PostboxLinkSharer = Future<ShareResult> Function(ShareParams params);

/// The message that goes with a shared postbox link.
String postboxLinkShareText(String url, String? monarch) =>
    'I found ${monarch == null ? 'a' : cypherPhrase(monarch)} postbox on '
    'The Postbox Game. Can you find it? $url';

/// Shares the link to a postbox the player has claimed (History's "Share
/// link"). Shows the location notice first, once per install, since the link
/// shows roughly where the box is; fetches the box's opaque link code; then
/// opens the share sheet.
Future<void> sharePostboxLink(
  BuildContext context, {
  required String postboxId,
  String? monarch,
  PostboxLinkFetcher fetchLinkCode = PostboxLinkService.fetchCode,
  PostboxLinkSharer? share,
}) async {
  if (!await confirmPostboxLinkPrivacy(context) || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final String code;
  try {
    code = await fetchLinkCode(postboxId);
  } catch (_) {
    messenger?.showSnackBar(const SnackBar(
      content: Text("Couldn't make a link just now. Check your connection "
          'and try again.'),
    ));
    return;
  }
  final url = postboxUrlFor(code, src: kPostboxSrcHistory);
  final result = await (share ?? SharePlus.instance.share)(
    ShareParams(text: postboxLinkShareText(url, monarch)),
  );
  if (result.status != ShareResultStatus.dismissed) {
    unawaited(Analytics.share(
      contentType: 'postbox_link',
      itemId: monarch ?? 'plain',
      method: result.raw.isNotEmpty ? result.raw : 'unknown',
    ));
  }
}
