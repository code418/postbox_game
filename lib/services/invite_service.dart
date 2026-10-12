import 'package:cloud_functions/cloud_functions.dart';
import 'package:postbox_game/firebase_functions_eu.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What `acceptInvite` says about a code before anything is written.
class InvitePreview {
  const InvitePreview({
    required this.inviterUid,
    required this.inviterName,
    required this.alreadyFriends,
  });

  final String inviterUid;
  final String inviterName;
  final bool alreadyFriends;
}

/// The outcome of a confirmed `acceptInvite`.
class InviteAcceptance {
  const InviteAcceptance({
    required this.inviterUid,
    required this.inviterName,
    required this.inviterListFull,
    required this.referralRecorded,
  });

  final String inviterUid;
  final String inviterName;

  /// The inviter's own list was full, so the friendship is one-way for now.
  final bool inviterListFull;

  /// The server credited the inviter with bringing in a new player.
  final bool referralRecorded;
}

/// Why an invite couldn't be used. Each maps to one line of copy and one
/// `invite_accepted` analytics result.
enum InviteFailure { invalid, notFound, selfInvite, friendLimit, error }

class InviteException implements Exception {
  const InviteException(this.reason);
  final InviteFailure reason;

  /// The analytics `result` for this failure.
  String get analyticsResult => switch (reason) {
        InviteFailure.invalid || InviteFailure.notFound => 'not_found',
        InviteFailure.selfInvite => 'self_invite',
        InviteFailure.friendLimit => 'friend_limit',
        InviteFailure.error => 'error',
      };

  String get message => switch (reason) {
        InviteFailure.invalid ||
        InviteFailure.notFound =>
          "That invite code doesn't match anyone. Check it and try again.",
        InviteFailure.selfInvite =>
          "That's your own invite code. Send it to a friend instead!",
        InviteFailure.friendLimit =>
          'Your friends list is full. Remove someone to make room.',
        InviteFailure.error =>
          "Couldn't open that invite right now. Please try again.",
      };

  @override
  String toString() => 'InviteException($reason)';
}

/// Maps a callable error code to an [InviteFailure]. Pure, for tests.
InviteFailure inviteFailureForCode(String code, String? message) =>
    switch (code) {
      'invalid-argument' => InviteFailure.invalid,
      'not-found' => InviteFailure.notFound,
      'failed-precondition' when message == 'self_invite' =>
        InviteFailure.selfInvite,
      'resource-exhausted' => InviteFailure.friendLimit,
      _ => InviteFailure.error,
    };

/// Client for the `getInviteCode` / `acceptInvite` callables
/// (`functions/src/invites.ts`).
class InviteService {
  static String _cacheKey(String uid) => 'invite_code_$uid';

  /// The player's own invite code, from the local cache if this device has
  /// fetched it before (it never changes), else from the server. Null when
  /// it can't be fetched (offline, or the backend isn't deployed yet); the
  /// caller falls back to the UID.
  static Future<String?> myCode(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_cacheKey(uid));
    if (cached != null) return cached;
    try {
      final result = await retryOnUnavailable(
          () => appFunctions.httpsCallable('getInviteCode').call());
      final code =
          Map<String, dynamic>.from(result.data as Map)['code'] as String?;
      if (code != null) await prefs.setString(_cacheKey(uid), code);
      return code;
    } catch (_) {
      return null;
    }
  }

  /// Looks the code up without writing anything, for the confirm dialog.
  static Future<InvitePreview> preview(String code) async {
    final data = await _call({'code': code, 'confirm': false});
    return InvitePreview(
      inviterUid: data['inviterUid'] as String,
      inviterName: _name(data['inviterName']),
      alreadyFriends: data['alreadyFriends'] == true,
    );
  }

  /// Makes the two players friends both ways.
  static Future<InviteAcceptance> accept(String code) async {
    // Safe to retry: the server's writes are arrayUnions plus a
    // create-once referral doc. The longer budget covers a brand-new
    // account whose users doc onUserCreated hasn't written yet, which the
    // server reports as `unavailable`.
    final data = await _call({'code': code, 'confirm': true}, maxRetries: 5);
    return InviteAcceptance(
      inviterUid: data['inviterUid'] as String,
      inviterName: _name(data['inviterName']),
      inviterListFull: data['inviterListFull'] == true,
      referralRecorded: data['referralRecorded'] == true,
    );
  }

  static String _name(Object? raw) {
    final name = raw is String ? raw.trim() : '';
    return name.isEmpty ? 'A player' : name;
  }

  static Future<Map<String, dynamic>> _call(
    Map<String, Object> params, {
    int maxRetries = 2,
  }) async {
    try {
      final result = await retryOnUnavailable(
        () => appFunctions.httpsCallable('acceptInvite').call(params),
        maxRetries: maxRetries,
      );
      return Map<String, dynamic>.from(result.data as Map);
    } on FirebaseFunctionsException catch (e) {
      throw InviteException(inviteFailureForCode(e.code, e.message));
    } catch (_) {
      throw const InviteException(InviteFailure.error);
    }
  }
}
