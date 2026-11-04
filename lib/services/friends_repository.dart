import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/analytics_user_properties.dart';

/// Outcome of a one-way add by UID.
enum AddFriendResult { added, self, notFound, alreadyFriends, listFull, failed }

/// The snackbar line for each [AddFriendResult].
String addFriendMessage(AddFriendResult result) => switch (result) {
      AddFriendResult.added => 'Friend added',
      AddFriendResult.self => "You can't add yourself",
      AddFriendResult.notFound => 'No player found with that UID',
      AddFriendResult.alreadyFriends => 'Already in your friends list',
      AddFriendResult.listFull =>
        'Friends list is full (${FriendsRepository.maxFriends} maximum)',
      AddFriendResult.failed => 'Failed to add friend. Please try again.',
    };

/// Adds friends to the signed-in player's own `users/{uid}.friends` list
/// (the only friends write clients may make). Shared by the Friends tab,
/// the "Added you" list and profile pages.
class FriendsRepository {
  FriendsRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  /// Must match the `request.resource.data.friends.size() <= 200` check in
  /// firestore.rules: that is the server-enforced cap; this is the client
  /// pre-check so players get a friendly error before the write.
  static const int maxFriends = 200;

  Future<AddFriendResult> addByUid(String myUid, String friendUid) async {
    if (myUid == friendUid) return AddFriendResult.self;
    try {
      // Check the friend exists AND whether they're already in the list.
      final results = await Future.wait([
        _firestore.collection('users').doc(friendUid).get(),
        _firestore.collection('users').doc(myUid).get(),
      ]);
      if (!results[0].exists) return AddFriendResult.notFound;
      final existing =
          (results[1].data()?['friends'] as List<dynamic>?) ?? const [];
      if (existing.contains(friendUid)) return AddFriendResult.alreadyFriends;
      if (existing.length >= maxFriends) return AddFriendResult.listFull;
      await _firestore.collection('users').doc(myUid).update({
        'friends': FieldValue.arrayUnion([friendUid]),
      });
      unawaited(Analytics.friendAdded());
      // existing pre-dates the arrayUnion, so the new count is +1. Push the
      // bucket directly rather than re-reading.
      unawaited(Analytics.setUserProperty(AnalyticsUserProps.kFriendCountBucket,
          friendCountBucket(existing.length + 1)));
      return AddFriendResult.added;
    } on FirebaseException catch (e) {
      // The rules reject a write past the cap even if the pre-check raced.
      return e.code == 'permission-denied'
          ? AddFriendResult.listFull
          : AddFriendResult.failed;
    } catch (_) {
      return AddFriendResult.failed;
    }
  }
}
