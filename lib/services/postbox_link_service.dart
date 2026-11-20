import 'package:postbox_game/firebase_functions_eu.dart';

/// Returns the link code for a postbox the player has claimed, minting it on
/// the server (`getPostboxLink`) the first time anyone shares that box.
/// Throws on failure (offline, not claimed, ...); callers show a snackbar.
typedef PostboxLinkFetcher = Future<String> Function(String postboxId);

/// The real fetcher. Codes never change for a box, so they are cached for
/// the life of the process: toggling the share-card QR off and on again, or
/// sharing the same box from History, costs one call.
class PostboxLinkService {
  PostboxLinkService._();

  static final Map<String, String> _codes = {};

  static Future<String> fetchCode(String postboxId) async {
    final cached = _codes[postboxId];
    if (cached != null) return cached;
    final result = await appFunctions
        .httpsCallable('getPostboxLink')
        .call<dynamic>({'postboxId': postboxId});
    final data = result.data;
    final code = data is Map ? data['code'] : null;
    if (code is! String || code.isEmpty) {
      throw StateError('getPostboxLink returned no code');
    }
    return _codes[postboxId] = code;
  }
}
