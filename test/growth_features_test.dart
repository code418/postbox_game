import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' show UserMetadata;
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/deep_links.dart';
import 'package:postbox_game/friends_screen.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/login/bloc/login_bloc.dart';
import 'package:postbox_game/services/friends_repository.dart';
import 'package:postbox_game/services/invite_service.dart';
import 'package:postbox_game/services/notification_preprompt.dart';
import 'package:postbox_game/services/pending_invite_store.dart';
import 'package:postbox_game/services/review_prompt_service.dart';
import 'package:postbox_game/widgets/share_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The growth loop from docs/marketing-plan.md: invite codes and links,
/// the parked-invite store, add-back, share cards, and the rating and
/// notification asks.
void main() {
  const emDash = '—';

  group('normaliseInviteCode', () {
    test('accepts a canonical code', () {
      expect(normaliseInviteCode('ABCD2345'), 'ABCD2345');
    });

    test('ignores case, spaces and hyphens', () {
      expect(normaliseInviteCode(' abcd-2345 '), 'ABCD2345');
      expect(normaliseInviteCode('ab cd 23 45'), 'ABCD2345');
    });

    test('reads the Crockford look-alikes I, L as 1 and O as 0', () {
      expect(normaliseInviteCode('ILO23456'), '11023456');
    });

    test('rejects U, wrong lengths and empties', () {
      expect(normaliseInviteCode('ABCDU345'), isNull);
      expect(normaliseInviteCode('ABC2345'), isNull);
      expect(normaliseInviteCode('ABCD23456'), isNull);
      expect(normaliseInviteCode(''), isNull);
      expect(normaliseInviteCode(null), isNull);
    });

    test('never mistakes a Firebase UID for a code', () {
      expect(normaliseInviteCode('aBcDeFgHiJkLmNoPqRsTuVwXyZ12'), isNull);
    });
  });

  group('parseInviteLink', () {
    test('reads the https App Link / Universal Link', () {
      expect(
          parseInviteLink(
              Uri.parse('https://the-postbox-game.web.app/invite/abcd2345')),
          'ABCD2345');
    });

    test("reads the invite page's custom scheme", () {
      expect(parseInviteLink(Uri.parse('postboxgame://invite/ABCD2345')),
          'ABCD2345');
    });

    test('ignores the widget claim link app_links also sees', () {
      expect(
          parseInviteLink(Uri.parse('postbox://claim?source=widget')), isNull);
    });

    test('ignores other hosts, paths and bad codes', () {
      expect(parseInviteLink(Uri.parse('https://example.com/invite/ABCD2345')),
          isNull);
      expect(
          parseInviteLink(
              Uri.parse('https://the-postbox-game.web.app/get/ABCD2345')),
          isNull);
      expect(
          parseInviteLink(Uri.parse(
              'https://the-postbox-game.web.app/invite/ABCD2345/extra')),
          isNull);
      expect(
          parseInviteLink(
              Uri.parse('https://the-postbox-game.web.app/invite/NOPE')),
          isNull);
      expect(parseInviteLink(null), isNull);
    });

    test('inviteUrlFor round-trips through the parser', () {
      expect(parseInviteLink(Uri.parse(inviteUrlFor('ABCD2345'))), 'ABCD2345');
    });
  });

  group('parseInviteInput', () {
    test('takes a bare or formatted code', () {
      expect(parseInviteInput('abcd-2345'), 'ABCD2345');
      expect(parseInviteInput(formatInviteCode('ABCD2345')), 'ABCD2345');
    });

    test('takes a pasted link, with or without the scheme', () {
      expect(parseInviteInput('https://the-postbox-game.web.app/invite/ABCD2345'),
          'ABCD2345');
      expect(parseInviteInput('the-postbox-game.web.app/invite/ABCD2345'),
          'ABCD2345');
    });

    test('returns null for a UID, so the field falls back to a UID add', () {
      expect(parseInviteInput('aBcDeFgHiJkLmNoPqRsTuVwXyZ12'), isNull);
    });
  });

  test('formatInviteCode splits a code for reading aloud', () {
    expect(formatInviteCode('ABCD2345'), 'ABCD-2345');
  });

  group('PendingInviteStore', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('a parked code is taken once', () async {
      await PendingInviteStore.save('ABCD2345');
      expect(await PendingInviteStore.take(), 'ABCD2345');
      expect(await PendingInviteStore.take(), isNull);
    });

    test('a code older than maxAge is dropped', () async {
      final saved = DateTime(2026, 10, 1);
      await PendingInviteStore.save('ABCD2345', now: saved);
      expect(
          await PendingInviteStore.take(
              now: saved.add(PendingInviteStore.maxAge + const Duration(hours: 1))),
          isNull);
    });

    test('saving bumps the signal for a mounted Home', () async {
      final before = PendingInviteStore.signal.value;
      await PendingInviteStore.save('ABCD2345');
      expect(PendingInviteStore.signal.value, before + 1);
    });
  });

  group('invite failures', () {
    test('map callable codes to reasons', () {
      expect(inviteFailureForCode('invalid-argument', null),
          InviteFailure.invalid);
      expect(inviteFailureForCode('not-found', null), InviteFailure.notFound);
      expect(inviteFailureForCode('failed-precondition', 'self_invite'),
          InviteFailure.selfInvite);
      expect(inviteFailureForCode('resource-exhausted', 'friend_limit'),
          InviteFailure.friendLimit);
      expect(inviteFailureForCode('unavailable', null), InviteFailure.error);
      expect(inviteFailureForCode('failed-precondition', 'other'),
          InviteFailure.error);
    });

    test('every message is in house style', () {
      for (final reason in InviteFailure.values) {
        final message = InviteException(reason).message;
        expect(message, isNot(contains(emDash)), reason: '$reason');
        expect(message.toLowerCase(), isNot(contains('james')));
      }
    });
  });

  group('buildInviteMessage with a code', () {
    test('is one invite link plus the typed form, no UID or store links', () {
      final msg = buildInviteMessage('uid123', code: 'ABCD2345');
      expect(msg, contains('https://the-postbox-game.web.app/invite/ABCD2345'));
      expect(msg, contains('ABCD-2345'));
      expect(msg, isNot(contains('uid123')));
      expect(msg, isNot(contains('play.google.com')));
      expect(msg, isNot(contains(emDash)));
    });

    test('falls back to the UID message without a code', () {
      expect(buildInviteMessage('uid123'), contains('uid123'));
    });
  });

  group('FriendsRepository.addByUid', () {
    late FakeFirebaseFirestore db;
    late FriendsRepository repo;

    setUp(() async {
      db = FakeFirebaseFirestore();
      repo = FriendsRepository(firestore: db);
      await db.collection('users').doc('me').set({'friends': <String>[]});
      await db.collection('users').doc('them').set({'displayName': 'Them'});
    });

    test('adds an existing player one-way', () async {
      expect(await repo.addByUid('me', 'them'), AddFriendResult.added);
      final me = await db.collection('users').doc('me').get();
      expect(me.data()!['friends'], ['them']);
    });

    test('refuses self, unknown players and duplicates', () async {
      expect(await repo.addByUid('me', 'me'), AddFriendResult.self);
      expect(await repo.addByUid('me', 'ghost'), AddFriendResult.notFound);
      await repo.addByUid('me', 'them');
      expect(await repo.addByUid('me', 'them'), AddFriendResult.alreadyFriends);
    });

    test('refuses past the friends cap', () async {
      await db.collection('users').doc('me').set({
        'friends': [
          for (var i = 0; i < FriendsRepository.maxFriends; i++) 'f$i'
        ],
      });
      expect(await repo.addByUid('me', 'them'), AddFriendResult.listFull);
    });

    test('every result has house-style copy', () {
      for (final r in AddFriendResult.values) {
        expect(addFriendMessage(r), isNot(contains(emDash)));
      }
    });
  });

  group('share cards', () {
    test('a single-box claim names its era', () {
      final card = claimShareCard(claimedCount: 1, points: 7, cypher: 'VR');
      expect(card.headline, 'I found a Victorian postbox!');
      expect(card.cypher, 'VR');
    });

    test('a multi-box claim, or no known cypher, gets no badge', () {
      expect(claimShareCard(claimedCount: 3, points: 6, cypher: 'VR').cypher,
          isNull);
      final plain = claimShareCard(claimedCount: 1, points: 2, cypher: 'PLAIN');
      expect(plain.cypher, isNull);
      expect(plain.headline, 'I claimed a postbox!');
    });

    test('the share text always carries the link', () {
      const link = 'https://the-postbox-game.web.app/invite/ABCD2345';
      final text = buildShareText(
          claimShareCard(claimedCount: 1, points: 12, cypher: 'EVIIIR'), link);
      expect(text, contains(link));
      expect(text, isNot(contains(emDash)));
    });

    testWidgets('the card lays out at its capture size without overflow',
        (tester) async {
      for (final data in [
        claimShareCard(claimedCount: 1, points: 12, cypher: 'EVIIIR', streak: 30),
        claimShareCard(claimedCount: 1, points: 4, cypher: 'SCOTTISH_CROWN'),
        claimShareCard(claimedCount: 4, points: 20, streak: 2),
        const ShareCardData(
            headline: "I've claimed 1,234 postboxes!",
            points: 5000,
            pointsText: '5,000 points in total',
            streak: 365),
      ]) {
        await tester.pumpWidget(MaterialApp(
          home: Center(
            child: ShareCard(
                data: data,
                link: 'https://the-postbox-game.web.app/invite/ABCD2345'),
          ),
        ));
        expect(tester.takeException(), isNull, reason: data.headline);
        expect(tester.getSize(find.byType(ShareCard)), kShareCardSize);
        // The card is public: it never names the guide.
        for (final t in tester.widgetList<Text>(find.byType(Text))) {
          expect((t.data ?? '').toLowerCase(), isNot(contains('james')));
        }
      }
    });
  });

  group('guide share nudges', () {
    test('have no em-dashes', () {
      for (var i = 0; i < 20; i++) {
        expect(JamesMessages.shareNudgeRare.resolve(), isNot(contains(emDash)));
      }
      expect(JamesMessages.shareNudgeStreak(7), isNot(contains(emDash)));
    });
  });

  group('reviewPromptTrigger', () {
    final now = DateTime(2026, 10, 12, 12);
    final oldAccount = now.subtract(const Duration(days: 30));

    String? trigger({
      DateTime? created,
      DateTime? last,
      bool rare = false,
      int streak = 0,
      bool otherDialog = false,
    }) =>
        reviewPromptTrigger(
          now: now,
          accountCreated: created ?? oldAccount,
          lastRequestedAt: last,
          rareClaim: rare,
          streak: streak,
          otherDialogShown: otherDialog,
        );

    test('asks after a rare claim or a streak landmark', () {
      expect(trigger(rare: true), 'rare_claim');
      expect(trigger(streak: 3), 'streak');
      expect(trigger(streak: 7), 'streak');
    });

    test('stays quiet on an ordinary claim', () {
      expect(trigger(streak: 4), isNull);
    });

    test('never on the first day, within the cooldown, or after a dialog', () {
      expect(
          trigger(
              rare: true, created: now.subtract(const Duration(hours: 3))),
          isNull);
      expect(
          trigger(rare: true, last: now.subtract(const Duration(days: 30))),
          isNull);
      expect(trigger(rare: true, last: now.subtract(kReviewCooldown)),
          'rare_claim');
      expect(trigger(rare: true, otherDialog: true), isNull);
      expect(
          reviewPromptTrigger(
            now: now,
            accountCreated: null,
            lastRequestedAt: null,
            rareClaim: true,
            streak: 0,
            otherDialogShown: false,
          ),
          isNull);
    });
  });

  group('shouldShowNotificationPrePrompt', () {
    test('asks once, only when notifications are not already on', () {
      expect(
          shouldShowNotificationPrePrompt(
              alreadyAnswered: false,
              status: AuthorizationStatus.notDetermined,
              isIOS: true),
          isTrue);
      expect(
          shouldShowNotificationPrePrompt(
              alreadyAnswered: true,
              status: AuthorizationStatus.notDetermined,
              isIOS: true),
          isFalse);
      expect(
          shouldShowNotificationPrePrompt(
              alreadyAnswered: false,
              status: AuthorizationStatus.authorized,
              isIOS: false),
          isFalse);
      expect(
          shouldShowNotificationPrePrompt(
              alreadyAnswered: false, status: null, isIOS: false),
          isFalse);
    });

    test('iOS never re-asks after a refusal; Android "denied" is unasked', () {
      expect(
          shouldShowNotificationPrePrompt(
              alreadyAnswered: false,
              status: AuthorizationStatus.denied,
              isIOS: true),
          isFalse);
      expect(
          shouldShowNotificationPrePrompt(
              alreadyAnswered: false,
              status: AuthorizationStatus.denied,
              isIOS: false),
          isTrue);
    });
  });

  group('isFirstSignIn', () {
    test('true when creation and last sign-in coincide', () {
      final t = DateTime(2026, 10, 12, 9);
      final user = MockUser(
          uid: 'u',
          metadata: UserMetadata(
              t.millisecondsSinceEpoch, t.millisecondsSinceEpoch + 400));
      expect(isFirstSignIn(user), isTrue);
    });

    test('false for a returning player', () {
      final t = DateTime(2026, 10, 12, 9);
      final user = MockUser(
          uid: 'u',
          metadata: UserMetadata(t.millisecondsSinceEpoch,
              t.add(const Duration(days: 3)).millisecondsSinceEpoch));
      expect(isFirstSignIn(user), isFalse);
    });
  });
}
