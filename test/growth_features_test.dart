import 'dart:io';
import 'dart:typed_data';

import 'package:exif/exif.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' show UserMetadata;
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:postbox_game/deep_links.dart';
import 'package:postbox_game/friends_screen.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/login/bloc/login_bloc.dart';
import 'package:postbox_game/notification_service.dart';
import 'package:postbox_game/services/friends_repository.dart';
import 'package:postbox_game/services/invite_service.dart';
import 'package:postbox_game/services/notification_preprompt.dart';
import 'package:postbox_game/services/pending_invite_store.dart';
import 'package:postbox_game/services/review_prompt_service.dart';
import 'package:postbox_game/theme.dart';
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

    test('shares link to the store landing page, tagged as a share', () {
      expect(kShareLinkUrl,
          'https://the-postbox-game.web.app/get?src=postbox_share');
      final text = buildShareText(
          claimShareCard(claimedCount: 1, points: 12, cypher: 'EVIIIR'),
          kShareLinkUrl);
      expect(text, endsWith('Claim your postboxes: $kShareLinkUrl'));
      expect(text, isNot(contains('Play with me')));
      expect(text, isNot(contains(emDash)));
    });

    testWidgets('the card prints the same link under the same call to action',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: ShareCard(
              data: claimShareCard(claimedCount: 1, points: 2, cypher: 'EIIR'),
              link: kShareLinkUrl),
        ),
      ));
      expect(
          find.text('Claim your postboxes: '
              'the-postbox-game.web.app/get?src=postbox_share'),
          findsOneWidget);
      expect(find.textContaining('Play with me'), findsNothing);
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
            child: ShareCard(data: data, link: kShareLinkUrl),
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

    group('with a photo', () {
      const link = kShareLinkUrl;
      final fixture =
          File('test/fixtures/share_photo_with_gps.jpg').readAsBytesSync();

      Iterable<String> texts(WidgetTester tester) => tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '');

      testWidgets('branded and clean variants lay out at the capture size',
          (tester) async {
        for (final aspect in [0.75, 0.8, 1.5]) {
          final photo = SharePhoto(bytes: fixture, aspectRatio: aspect);
          for (final data in [
            claimShareCard(
                claimedCount: 1, points: 7, cypher: 'VR', streak: 30),
            claimShareCard(claimedCount: 1, points: 4, cypher: 'SCOTTISH_CROWN'),
            claimShareCard(claimedCount: 3, points: 6),
          ]) {
            for (final clean in [false, true]) {
              await tester.pumpWidget(MaterialApp(
                home: Center(
                  child: ShareCard(
                    data: data.copyWith(photo: photo, clean: clean),
                    link: link,
                    photoScale: 2,
                    photoOffset: const Offset(40, -30),
                  ),
                ),
              ));
              final why = '${data.headline} aspect $aspect clean $clean';
              expect(tester.takeException(), isNull, reason: why);
              expect(tester.getSize(find.byType(ShareCard)), kShareCardSize,
                  reason: why);
            }
          }
        }
      });

      testWidgets('the branded strip carries the era and the link',
          (tester) async {
        await tester.pumpWidget(MaterialApp(
          home: Center(
            child: ShareCard(
              data: claimShareCard(claimedCount: 1, points: 7, cypher: 'VR')
                  .copyWith(
                      photo: SharePhoto(bytes: fixture, aspectRatio: 0.75)),
              link: link,
            ),
          ),
        ));
        expect(texts(tester), contains('Victoria (1837–1901)'));
        expect(texts(tester), contains('The Postbox Game'));
        expect(texts(tester).any((t) => t.contains('the-postbox-game.web.app')),
            isTrue);
      });

      testWidgets('the clean variant shows only the cypher caption',
          (tester) async {
        await tester.pumpWidget(MaterialApp(
          home: Center(
            child: ShareCard(
              data: claimShareCard(claimedCount: 1, points: 7, cypher: 'VR')
                  .copyWith(
                      photo: SharePhoto(bytes: fixture, aspectRatio: 0.75),
                      clean: true),
              link: link,
            ),
          ),
        ));
        expect(texts(tester), containsAll(['VR', 'Victoria (1837–1901)']));
        expect(texts(tester).any((t) => t.contains('web.app')), isFalse);
        expect(texts(tester), isNot(contains('The Postbox Game')));
      });

      test('a clean share still sends the link in its text', () {
        final data = claimShareCard(claimedCount: 1, points: 7, cypher: 'VR')
            .copyWith(
                photo: SharePhoto(bytes: fixture, aspectRatio: 1),
                clean: true);
        expect(buildShareText(data, link), contains(link));
        expect(data.shareStyle, 'photo_clean');
        expect(data.copyWith(clean: false).shareStyle, 'photo');
        expect(data.copyWith(clearPhoto: true).shareStyle, 'card');
      });

      test('framing never lets the photo uncover the card', () {
        // A 4:5 photo exactly covers the 4:5 card: no pan at 1x.
        expect(
            clampPhotoOffset(const Offset(50, 50),
                scale: 1, aspectRatio: 0.8),
            Offset.zero);
        // A 3:2 landscape overhangs sideways only: (450 * 1.5 - 360) / 2.
        expect(
            clampPhotoOffset(const Offset(-500, 80),
                scale: 1, aspectRatio: 1.5),
            const Offset(-157.5, 0));
        // At 2x the card can pan by half its own size again.
        expect(
            clampPhotoOffset(const Offset(999, 999),
                scale: 2, aspectRatio: 0.8),
            const Offset(180, 225));
      });

      testWidgets(
          'the shared PNG is re-rendered pixels, with none of the photo\'s '
          'GPS or camera metadata', (tester) async {
        // The fixture really does carry a GPS block and a camera make.
        final source = await tester.runAsync(() => readExifFromBytes(fixture));
        expect(source!.keys, contains('GPS GPSLatitude'));
        expect(source.keys, contains('Image Make'));

        final key = GlobalKey();
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        final photo = (await tester.runAsync(() async {
          final p = await SharePhoto.decode(fixture);
          await precacheImage(
              MemoryImage(fixture), tester.element(find.byType(SizedBox)));
          return p;
        }))!;
        expect(photo.aspectRatio, closeTo(96 / 120, 0.01));
        await tester.pumpWidget(MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: key,
              child: ShareCard(
                data: claimShareCard(claimedCount: 1, points: 7, cypher: 'VR')
                    .copyWith(photo: photo),
                link: link,
              ),
            ),
          ),
        ));
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final png = (await tester.runAsync(() => renderShareCardPng(boundary)))!;

        // PNG signature, then only chunks that hold no metadata.
        expect(png.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
        final chunks = <String>[];
        final view = ByteData.sublistView(png);
        for (var i = 8; i + 8 <= png.length;) {
          final length = view.getUint32(i);
          chunks.add(String.fromCharCodes(png.sublist(i + 4, i + 8)));
          i += 12 + length;
        }
        expect(chunks.first, 'IHDR');
        expect(chunks.last, 'IEND');
        for (final c in ['eXIf', 'tEXt', 'iTXt', 'zTXt']) {
          expect(chunks, isNot(contains(c)));
        }
        expect(await tester.runAsync(() => readExifFromBytes(png)), isEmpty);

        // 1080 x 1350, whatever the photo's own size.
        expect(view.getUint32(16), 1080);
        expect(view.getUint32(20), 1350);
      });
    });

    group('share sheet photo flow', () {
      const link = kShareLinkUrl;
      final fixture =
          File('test/fixtures/share_photo_with_gps.jpg').readAsBytesSync();

      // Always under the real app theme: its buttons have an infinite
      // minimum width, which the default test theme hides (see the layout
      // test below).
      Future<List<ImageSource>> pumpSheet(WidgetTester tester) async {
        final picks = <ImageSource>[];
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ShareCardSheet(
              data: claimShareCard(claimedCount: 1, points: 7, cypher: 'VR'),
              link: link,
              contentType: 'claim',
              itemId: 'VR',
              pickPhoto: (source) async {
                picks.add(source);
                return fixture;
              },
            ),
          ),
        ));
        return picks;
      }

      Finder button(String label) => find
          .ancestor(
              of: find.text(label),
              matching: find.bySubtype<ButtonStyleButton>())
          .first;

      // The theme sets minimumSize: Size(double.infinity, 52) on filled and
      // outlined buttons. In a bare Row that is an unbounded minimum, so the
      // row fails layout and, in a release build, paints nothing: the card
      // showed with no Add photo and no Share button under it.
      for (final theme in {
        'light': AppTheme.light,
        'dark': AppTheme.dark,
      }.entries) {
        testWidgets(
            'Add photo and Share lay out side by side under the ${theme.key} '
            'app theme', (tester) async {
          tester.view.physicalSize = const Size(1080, 2400);
          tester.view.devicePixelRatio = 2.625;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(MaterialApp(
            theme: theme.value,
            home: Scaffold(
              body: Builder(
                // The real entry point, as the claim sheet calls it.
                builder: (context) => TextButton(
                  onPressed: () => showShareCardSheet(
                    context,
                    data: claimShareCard(
                        claimedCount: 1, points: 2, cypher: 'EIIR'),
                    contentType: 'claim',
                    itemId: 'EIIR',
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ));
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          // Every entry point shares the generic link, not an invite code.
          expect(find.textContaining('get?src=postbox_share'), findsOneWidget);

          final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
          final add = tester.getRect(button('Add photo'));
          final share = tester.getRect(button('Share'));
          for (final rect in [add, share]) {
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(screen.width));
            expect(rect.bottom, lessThanOrEqualTo(screen.height));
            expect(rect.height, greaterThanOrEqualTo(48));
          }
          expect(add.right, lessThanOrEqualTo(share.left));
          expect(add.center.dy, closeTo(share.center.dy, 1));
        });
      }

      /// Lets the real image decode behind a pick finish.
      Future<void> settleDecode(WidgetTester tester) async {
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)));
          await tester.pump();
        }
      }

      testWidgets('warns about what a photo can show before the first pick',
          (tester) async {
        SharedPreferences.setMockInitialValues({});
        final picks = await pumpSheet(tester);
        expect(find.text('Hide branding'), findsNothing);

        await tester.tap(find.text('Add photo'));
        await tester.pumpAndSettle();
        expect(find.text(kSharePhotoPrivacyTitle), findsOneWidget);
        expect(find.text(kSharePhotoPrivacyBody), findsOneWidget);
        expect(kSharePhotoPrivacyBody, contains('where you live'));
        // Side by side: an unstyled themed FilledButton would take the whole
        // action row and push Cancel above it.
        final cancel = tester.getRect(button('Cancel'));
        final gotIt = tester.getRect(button('Got it'));
        expect(cancel.right, lessThanOrEqualTo(gotIt.left));
        expect(cancel.center.dy, closeTo(gotIt.center.dy, 1));

        // Cancel opens no picker and remembers nothing.
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(picks, isEmpty);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool(kSharePhotoPrivacyAckKey), isNull);

        await tester.tap(find.text('Add photo'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Got it'));
        await tester.pumpAndSettle();
        expect(prefs.getBool(kSharePhotoPrivacyAckKey), isTrue);
        await tester.tap(find.text('Choose from library'));
        await tester.pump();
        await settleDecode(tester);

        expect(picks, [ImageSource.gallery]);
        expect(find.text('Change photo'), findsOneWidget);
        expect(find.text('Hide branding'), findsOneWidget);
        expect(find.text(kSharePhotoReminder), findsOneWidget);

        // Acknowledged: the next change goes straight to the source choice.
        await tester.tap(find.text('Change photo'));
        await tester.pumpAndSettle();
        expect(find.text(kSharePhotoPrivacyTitle), findsNothing);
        expect(find.text('Take a photo'), findsOneWidget);
      });

      testWidgets('removing the photo returns to the plain card',
          (tester) async {
        SharedPreferences.setMockInitialValues({kSharePhotoPrivacyAckKey: true});
        await pumpSheet(tester);
        await tester.tap(find.text('Add photo'));
        await tester.pumpAndSettle();
        expect(find.text(kSharePhotoPrivacyTitle), findsNothing);
        await tester.tap(find.text('Take a photo'));
        await tester.pump();
        await settleDecode(tester);
        expect(find.text('Hide branding'), findsOneWidget);

        await tester.tap(find.byTooltip('Remove photo'));
        await tester.pump();
        expect(find.text('Hide branding'), findsNothing);
        expect(find.text(kSharePhotoReminder), findsNothing);
        expect(find.text('Add photo'), findsOneWidget);
      });
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

  group('notificationSettingsAction', () {
    test('nothing to offer when notifications work or status is unknown', () {
      for (final isIOS in [true, false]) {
        for (final status in [
          AuthorizationStatus.authorized,
          AuthorizationStatus.provisional,
          null,
        ]) {
          expect(notificationSettingsAction(status: status, isIOS: isIOS),
              NotificationSettingsAction.none,
              reason: '$status on ${isIOS ? 'iOS' : 'Android'}');
        }
      }
    });

    test('iOS: prompt when unasked, system settings once refused', () {
      expect(
          notificationSettingsAction(
              status: AuthorizationStatus.notDetermined, isIOS: true),
          NotificationSettingsAction.request);
      expect(
          notificationSettingsAction(
              status: AuthorizationStatus.denied, isIOS: true),
          NotificationSettingsAction.openSettings);
    });

    test('Android: "denied" may be unasked, so prompt until it comes back '
        'refused', () {
      expect(
          notificationSettingsAction(
              status: AuthorizationStatus.denied, isIOS: false),
          NotificationSettingsAction.request);
      expect(
          notificationSettingsAction(
              status: AuthorizationStatus.denied,
              isIOS: false,
              promptRefused: true),
          NotificationSettingsAction.openSettings);
    });
  });

  group('NotificationService.usesApns', () {
    test('only the native Apple apps present FCM through APNs', () {
      for (final platform in TargetPlatform.values) {
        expect(
            NotificationService.usesApns(isWeb: false, platform: platform),
            platform == TargetPlatform.iOS ||
                platform == TargetPlatform.macOS,
            reason: '$platform');
        // Web on an iPhone reports TargetPlatform.iOS but uses web push.
        expect(NotificationService.usesApns(isWeb: true, platform: platform),
            isFalse,
            reason: 'web on $platform');
      }
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
