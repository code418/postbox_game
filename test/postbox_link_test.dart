// Postbox links (/postbox/CODE): parsing, the parked-link store, the screen
// a link opens, the share card's optional QR code and History's share link.
// The backend half is tested in functions/src/test/test.index.ts.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:postbox_game/deep_links.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/james_strip.dart';
import 'package:postbox_game/location_service.dart';
import 'package:postbox_game/postbox_link/postbox_link_screen.dart';
import 'package:postbox_game/postbox_link/postbox_link_status.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/services/pending_postbox_link_store.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/widgets/claim_quiz_sheet.dart';
import 'package:postbox_game/widgets/postbox_link_share.dart';
import 'package:postbox_game/widgets/share_card.dart';
import 'package:postbox_game/widgets/share_qr.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeResult<T> implements HttpsCallableResult<T> {
  _FakeResult(this.data);
  @override
  final T data;
}

class _FakeFunctionsException extends FirebaseFunctionsException {
  _FakeFunctionsException({required super.code, required super.message});
}

class _StubRemoteConfig extends Fake implements FirebaseRemoteConfig {
  @override
  bool getBool(String key) => false;
  @override
  String getString(String key) => '';
  @override
  double getDouble(String key) => 0.0;
}

Position _pos() => Position(
      latitude: 51.5,
      longitude: -0.12,
      timestamp: DateTime.now(),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

const String _code = 'ABCDEFGHJK';
const String _emDash = '—';

Map<String, dynamic> _status(String proximity,
        {String? county = 'Devon', int total = 12}) =>
    {
      'found': true,
      'proximity': proximity,
      'info': {
        'monarch': 'VR',
        'label': 'Victoria (1837–1901)',
        'phrase': 'a Victorian',
        'points': 7,
        'county': county,
        'claims': {'total': total},
        'map': null,
      },
    };

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => '.',
    );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RemoteConfigService.instance =
        RemoteConfigService(remoteConfig: _StubRemoteConfig());
  });
  tearDown(RemoteConfigService.resetForTest);

  group('parsePostboxLink', () {
    test('reads the https App Link and the custom scheme', () {
      expect(
          parsePostboxLink(
              Uri.parse('https://the-postbox-game.web.app/postbox/$_code')),
          const PostboxLink(_code));
      expect(parsePostboxLink(Uri.parse('postboxgame://postbox/$_code')),
          const PostboxLink(_code));
    });

    test('normalises the code and keeps a cleaned src tag', () {
      expect(
          parsePostboxLink(Uri.parse(
              'https://the-postbox-game.web.app/postbox/abcd-efgh-jk/?src=QR')),
          const PostboxLink(_code, src: 'qr'));
      expect(
          parsePostboxLink(Uri.parse(
              'postboxgame://postbox/$_code?src=Reddit%20Postboxes!')),
          const PostboxLink(_code, src: 'redditpostboxes'));
    });

    test('rejects other links, including invites and the widget', () {
      for (final link in [
        'https://the-postbox-game.web.app/invite/ABCD2345',
        'https://the-postbox-game.web.app/postbox/ABCD2345', // invite length
        'https://the-postbox-game.web.app/postbox/osm_123456',
        'https://the-postbox-game.web.app/postbox/$_code/extra',
        'https://example.com/postbox/$_code',
        'postboxgame://invite/$_code',
        'postbox://claim?source=widget',
      ]) {
        expect(parsePostboxLink(Uri.parse(link)), isNull, reason: link);
      }
      expect(parsePostboxLink(null), isNull);
      // ...and the invite parser ignores postbox links.
      expect(
          parseInviteLink(
              Uri.parse('https://the-postbox-game.web.app/postbox/$_code')),
          isNull);
    });

    test('postboxUrlFor round-trips through the parser', () {
      final url = postboxUrlFor(_code, src: kPostboxSrcHistory);
      expect(url,
          'https://the-postbox-game.web.app/postbox/$_code?src=history_link');
      expect(parsePostboxLink(Uri.parse(url)),
          const PostboxLink(_code, src: kPostboxSrcHistory));
    });

    test('sanitisePostboxSrc matches the web pages', () {
      expect(sanitisePostboxSrc('Share_QR-2'), 'share_qr-2');
      expect(sanitisePostboxSrc('!!!'), isNull);
      expect(sanitisePostboxSrc(null), isNull);
      expect(sanitisePostboxSrc('x' * 60)!.length, 40);
    });
  });

  group('PendingPostboxLinkStore', () {
    test('a parked link is taken once, with its src', () async {
      await PendingPostboxLinkStore.save(const PostboxLink(_code, src: 'qr'));
      expect(await PendingPostboxLinkStore.take(),
          const PostboxLink(_code, src: 'qr'));
      expect(await PendingPostboxLinkStore.take(), isNull);
    });

    test('a link older than an hour is dropped', () async {
      final then = DateTime(2026, 11, 20, 12);
      await PendingPostboxLinkStore.save(const PostboxLink(_code), now: then);
      expect(
          await PendingPostboxLinkStore.take(
              now: then.add(const Duration(minutes: 61))),
          isNull);
    });

    test('a later link without src clears the earlier src', () async {
      await PendingPostboxLinkStore.save(const PostboxLink(_code, src: 'qr'));
      await PendingPostboxLinkStore.save(const PostboxLink(_code));
      expect(await PendingPostboxLinkStore.take(), const PostboxLink(_code));
    });

    test('saving bumps the signal for a mounted Home', () async {
      final before = PendingPostboxLinkStore.signal.value;
      await PendingPostboxLinkStore.save(const PostboxLink(_code));
      expect(PendingPostboxLinkStore.signal.value, before + 1);
    });
  });

  group('postboxLinkStatus wire models', () {
    test('parse the callable response forgivingly', () {
      final status = PostboxLinkStatus.fromCallable(_status('shortWalk'));
      expect(status.found, isTrue);
      expect(status.proximity, PostboxProximity.shortWalk);
      expect(status.info.headline, 'A Victorian postbox');
      expect(status.info.points, 7);
      expect(status.info.claimsText, 'Claimed 12 times before');
      expect(PostboxLinkStatus.fromCallable(null).found, isFalse);
      expect(PostboxProximity.fromWire('somethingNew'),
          PostboxProximity.unknown);
      final plain = PostboxPublicInfo.fromJson({'claims': {'total': 1}});
      expect(plain.headline, 'A postbox');
      expect(plain.points, 2);
      expect(plain.claimsText, 'Claimed once before');
      expect(PostboxPublicInfo.fromJson({}).claimsText, 'Never claimed before');
    });
  });

  group('sharePostboxIdFor', () {
    int points(String? m) => switch (m) {
          'VR' => 7,
          'EVIIIR' => 12,
          _ => 2,
        };
    final scanned = <String, dynamic>{
      'osm_1': {'monarch': 'EIIR'},
      'osm_2': {'monarch': 'VR'},
      'osm_3': {'monarch': 'VR'},
      'osm_4': <String, dynamic>{},
    };

    test('picks the rarest claimed box the scan saw, first on a tie', () {
      expect(sharePostboxIdFor(['osm_1', 'osm_2', 'osm_3'], scanned, points),
          'osm_2');
      expect(sharePostboxIdFor(['osm_4', 'osm_1'], scanned, points), 'osm_4');
    });

    test('falls back to the first claimed id, or null when unknown', () {
      expect(sharePostboxIdFor(['osm_9'], scanned, points), 'osm_9');
      expect(sharePostboxIdFor(['osm_9', 'osm_2'], scanned, points), 'osm_2');
      expect(sharePostboxIdFor(null, scanned, points), isNull);
      expect(sharePostboxIdFor(const [], scanned, points), isNull);
    });
  });

  group('copy', () {
    test("the guide's postbox-link lines keep house style", () {
      // Variants are private: sample each pool until every one has shown.
      Set<String> all(JamesMessage m) =>
          {for (var i = 0; i < 200; i++) m.resolve()};
      final lines = [
        ...all(JamesMessages.postboxLinkClaimable),
        ...all(JamesMessages.postboxLinkVeryClose),
        ...all(JamesMessages.postboxLinkShortWalk),
        ...all(JamesMessages.postboxLinkUnderKm),
        ...all(JamesMessages.postboxLinkClaimedToday),
        ...all(JamesMessages.postboxLinkNotFound),
        ...all(JamesMessages.postboxLinkNoLocation),
        JamesMessages.postboxLinkFar('Devon'),
        JamesMessages.postboxLinkFar(null),
      ];
      for (final line in lines) {
        expect(line, isNot(contains(_emDash)), reason: line);
        expect(line.toLowerCase(), isNot(contains('james')), reason: line);
        expect(line.toLowerCase(), isNot(contains('postie')), reason: line);
      }
    });

    test('the History share text names the era and carries the link', () {
      final url = postboxUrlFor(_code, src: kPostboxSrcHistory);
      expect(postboxLinkShareText(url, 'VR'),
          'I found a Victorian postbox on The Postbox Game. Can you find it? '
          '$url');
      expect(postboxLinkShareText(url, null), startsWith('I found a postbox'));
      expect(postboxLinkShareText(url, 'EIIR'), isNot(contains(_emDash)));
    });

    test('the privacy notice says what the link gives away', () {
      expect(kPostboxLinkPrivacyBody, contains('county'));
      expect(kPostboxLinkPrivacyBody, contains('where you live'));
      expect(kPostboxLinkPrivacyBody, isNot(contains(_emDash)));
    });
  });

  group('share card QR', () {
    const qr = SharePostboxQr(_code);

    test('links to the postbox page, tagged by where it was shared', () {
      expect(qr.qrUrl, 'https://the-postbox-game.web.app/postbox/$_code?src=qr');
      expect(qr.textUrl,
          'https://the-postbox-game.web.app/postbox/$_code?src=share_text');
      expect(qr.printedUrl, 'the-postbox-game.web.app/postbox/$_code');
    });

    test('stays a small QR symbol, so it scans off a phone screen', () {
      // Worst case: every code is the same length, so one is enough.
      final painter = ShareQrPainter(qr.qrUrl);
      expect(painter.typeNumber, lessThanOrEqualTo(4));
      // 100 logical px at 3x: at least 7 device pixels per module.
      expect(300 / painter.totalModules, greaterThanOrEqualTo(7));
    });

    test('the share text links to the postbox only when the QR shows', () {
      final card = claimShareCard(claimedCount: 1, points: 7, cypher: 'VR');
      expect(buildShareText(card, kShareLinkUrl), contains(kShareLinkUrl));
      final withQr = card.copyWith(qr: qr);
      expect(withQr.showsQr, isTrue);
      expect(buildShareText(withQr, kShareLinkUrl), contains(qr.textUrl));
      expect(buildShareText(withQr, kShareLinkUrl),
          isNot(contains(kShareLinkUrl)));
      // A clean photo has no strip to put it in, so no QR and no page link.
      final clean = withQr.copyWith(
          photo: SharePhoto(bytes: Uint8List(0), aspectRatio: 1), clean: true);
      expect(clean.showsQr, isFalse);
      expect(buildShareText(clean, kShareLinkUrl), contains(kShareLinkUrl));
      expect(withQr.copyWith(clearQr: true).qr, isNull);
    });

    testWidgets('every claim card lays out with the QR at capture size',
        (tester) async {
      for (final data in [
        claimShareCard(claimedCount: 1, points: 12, cypher: 'EVIIIR', streak: 30),
        claimShareCard(claimedCount: 1, points: 4, cypher: 'SCOTTISH_CROWN'),
        claimShareCard(claimedCount: 4, points: 20, streak: 2),
        claimShareCard(claimedCount: 1, points: 2),
      ]) {
        await tester.pumpWidget(MaterialApp(
          home: Center(
            child: ShareCard(data: data.copyWith(qr: qr), link: kShareLinkUrl),
          ),
        ));
        expect(tester.takeException(), isNull, reason: data.headline);
        expect(tester.getSize(find.byType(ShareCard)), kShareCardSize);
        final painters = tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((p) => p.painter)
            .whereType<ShareQrPainter>();
        expect(painters.map((p) => p.data), [qr.qrUrl]);
        expect(find.text('Scan to find this postbox'), findsOneWidget);
        expect(find.text(qr.printedUrl), findsOneWidget);
        for (final t in tester.widgetList<Text>(find.byType(Text))) {
          expect((t.data ?? '').toLowerCase(), isNot(contains('james')));
        }
      }
    });

    testWidgets('the captured card is still 1080 x 1350', (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: key,
            child: ShareCard(
              data: claimShareCard(claimedCount: 1, points: 7, cypher: 'VR')
                  .copyWith(qr: qr),
              link: kShareLinkUrl,
            ),
          ),
        ),
      ));
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final png = await tester.runAsync(() => renderShareCardPng(boundary));
      expect(png, isNotNull);
      final size = await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(png!);
        final frame = await codec.getNextFrame();
        return Size(frame.image.width.toDouble(), frame.image.height.toDouble());
      });
      expect(size, const Size(1080, 1350));
    });
  });

  group('share sheet QR switch', () {
    Future<List<String>> pumpSheet(WidgetTester tester,
        {String? qrPostboxId = 'osm_42',
        Future<String> Function(String id)? fetch}) async {
      final fetched = <String>[];
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: ShareCardSheet(
            data: claimShareCard(claimedCount: 1, points: 7, cypher: 'VR'),
            link: kShareLinkUrl,
            contentType: 'claim',
            itemId: 'VR',
            qrPostboxId: qrPostboxId,
            fetchLinkCode: (id) {
              fetched.add(id);
              return fetch == null ? Future<String>.value(_code) : fetch(id);
            },
          ),
        ),
      ));
      return fetched;
    }

    Iterable<ShareQrPainter> qrPainters(WidgetTester tester) => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((p) => p.painter)
        .whereType<ShareQrPainter>();

    testWidgets('is not offered without a claimed box', (tester) async {
      await pumpSheet(tester, qrPostboxId: null);
      expect(find.text('Add postbox QR'), findsNothing);
    });

    testWidgets('warns first, then fetches the link once and draws it',
        (tester) async {
      final fetched = await pumpSheet(tester);
      expect(find.text('Add postbox QR'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(qrPainters(tester), isEmpty);

      await tester.tap(find.text('Add postbox QR'));
      await tester.pumpAndSettle();
      expect(find.text(kPostboxLinkPrivacyTitle), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(fetched, isEmpty);
      expect(qrPainters(tester), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kPostboxLinkPrivacyAckKey), isNull);

      await tester.tap(find.text('Add postbox QR'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      expect(fetched, ['osm_42']);
      expect(prefs.getBool(kPostboxLinkPrivacyAckKey), isTrue);
      expect(qrPainters(tester).map((p) => p.data),
          [postboxUrlFor(_code, src: kPostboxSrcShareQr)]);
      expect(tester.takeException(), isNull);

      // Off and on again: no second notice.
      await tester.tap(find.text('Add postbox QR'));
      await tester.pumpAndSettle();
      expect(qrPainters(tester), isEmpty);
      await tester.tap(find.text('Add postbox QR'));
      await tester.pumpAndSettle();
      expect(find.text(kPostboxLinkPrivacyTitle), findsNothing);
      expect(qrPainters(tester), hasLength(1));
    });

    testWidgets('a failed fetch leaves the QR off and says so', (tester) async {
      SharedPreferences.setMockInitialValues({kPostboxLinkPrivacyAckKey: true});
      await pumpSheet(tester,
          fetch: (_) => Future<String>.error(Exception('offline')));
      await tester.tap(find.text('Add postbox QR'));
      await tester.pumpAndSettle();
      expect(qrPainters(tester), isEmpty);
      expect(find.textContaining("Couldn't make a link"), findsOneWidget);
    });

    testWidgets('Add photo and Share still lay out with the switch present',
        (tester) async {
      await pumpSheet(tester);
      Finder button(String label) => find
          .ancestor(
              of: find.text(label),
              matching: find.bySubtype<ButtonStyleButton>())
          .first;
      final add = tester.getRect(button('Add photo'));
      final share = tester.getRect(button('Share'));
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      for (final rect in [add, share]) {
        expect(rect.right, lessThanOrEqualTo(screen.width));
        expect(rect.bottom, lessThanOrEqualTo(screen.height));
        expect(rect.height, greaterThanOrEqualTo(48));
      }
      expect(add.right, lessThanOrEqualTo(share.left));
    });
  });

  group('History share link', () {
    testWidgets('warns, fetches, then shares the tagged link', (tester) async {
      final fetched = <String>[];
      final shared = <ShareParams>[];
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => sharePostboxLink(
                context,
                postboxId: 'osm_7',
                monarch: 'VR',
                fetchLinkCode: (id) async {
                  fetched.add(id);
                  return _code;
                },
                share: (params) async {
                  shared.add(params);
                  return const ShareResult('ok', ShareResultStatus.success);
                },
              ),
              child: const Text('share'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('share'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(fetched, isEmpty);
      expect(shared, isEmpty);

      await tester.tap(find.text('share'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      expect(fetched, ['osm_7']);
      expect(shared.single.text,
          contains(postboxUrlFor(_code, src: kPostboxSrcHistory)));
      expect(shared.single.text, isNot(contains('osm_7')));
    });
  });

  group('PostboxLinkScreen', () {
    Future<List<Map<String, dynamic>>> pumpScreen(
      WidgetTester tester, {
      required FutureOr<Object?> Function(Map<String, dynamic>) respond,
      Future<Position> Function()? position,
      NearbyPostboxesCallableFn? nearby,
    }) async {
      final calls = <Map<String, dynamic>>[];
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: PostboxLinkScreen(
          code: _code,
          streakStream: Stream<int?>.value(null),
          positionProvider: position ?? () async => _pos(),
          statusCallable: (payload) async {
            calls.add(payload);
            return _FakeResult<dynamic>(await respond(payload));
          },
          nearbyCallableForSheet: nearby ??
              (_) async => _FakeResult<dynamic>({
                    'counts': {'total': 0, 'claimedToday': 0},
                    'points': {'min': 0, 'max': 0},
                    'postboxes': <String, dynamic>{},
                    'compass': <String, dynamic>{},
                    'claimedCompass': <String, dynamic>{},
                  }),
          startScoringCallableForSheet: (_) async =>
              _FakeResult<dynamic>({'found': false}),
        ),
      ));
      await tester.pump();
      await tester.pump();
      return calls;
    }

    /// Runs out the guide's message timers and the rescan cooldown, so the
    /// test ends with no timers pending.
    Future<void> drain(WidgetTester tester) async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
    }

    testWidgets('sends the code and position, shows the box and the band',
        (tester) async {
      final calls = await pumpScreen(tester,
          respond: (_) => _status('shortWalk'));
      expect(calls.single, {'code': _code, 'lat': 51.5, 'lng': -0.12});
      expect(find.text('A Victorian postbox'), findsOneWidget);
      expect(find.text('7 points'), findsOneWidget);
      expect(find.text('Claimed 12 times before'), findsOneWidget);
      expect(find.text('Somewhere in Devon'), findsOneWidget);
      expect(find.text('A short walk away'), findsOneWidget);
      // Its own guide strip: pushed screens sit outside Home's.
      expect(find.byType(JamesStrip), findsOneWidget);
      expect(find.byType(ClaimQuizSheet), findsNothing);
      await drain(tester);
    });

    testWidgets('far away names the county, never a direction',
        (tester) async {
      await pumpScreen(tester, respond: (_) => _status('far'));
      expect(find.text('More than a kilometre away'), findsOneWidget);
      expect(find.textContaining('somewhere in Devon'), findsOneWidget);
      for (final word in ['north', 'south', 'east', 'west']) {
        expect(find.textContaining(word), findsNothing, reason: word);
      }
      await drain(tester);
    });

    testWidgets('at the box it opens the claim sheet once', (tester) async {
      await pumpScreen(tester, respond: (_) => _status('claimable'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ClaimQuizSheet), findsOneWidget);
      await drain(tester);
    });

    testWidgets('very close offers a try, which opens the claim sheet',
        (tester) async {
      await pumpScreen(tester, respond: (_) => _status('veryClose'));
      expect(find.text('Very close'), findsOneWidget);
      expect(find.byType(ClaimQuizSheet), findsNothing);
      await tester.tap(find.text('Try to claim'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ClaimQuizSheet), findsOneWidget);
      await drain(tester);
    });

    testWidgets('claimed today says to come back tomorrow', (tester) async {
      await pumpScreen(tester, respond: (_) => _status('claimedToday'));
      expect(find.text('Claimed today'), findsOneWidget);
      expect(find.text('Try to claim'), findsNothing);
      expect(find.text('Claim it'), findsNothing);
      await drain(tester);
    });

    testWidgets('without location it asks without a position', (tester) async {
      final calls = await pumpScreen(
        tester,
        respond: (_) => _status('unknown'),
        position: () async => throw const LocationServiceException(
            LocationErrorKind.servicesDisabled, 'off'),
      );
      expect(calls.single, {'code': _code});
      expect(find.text('Where are you?'), findsOneWidget);
      expect(find.text('Open location settings'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('an unknown code shows not found', (tester) async {
      await pumpScreen(tester, respond: (_) => {'found': false});
      expect(find.text("We can't find that postbox"), findsOneWidget);
      await drain(tester);
    });

    testWidgets('a failure offers a retry that asks again', (tester) async {
      var attempts = 0;
      final calls = await pumpScreen(tester, respond: (_) {
        attempts++;
        if (attempts == 1) {
          throw _FakeFunctionsException(code: 'unavailable', message: 'down');
        }
        return _status('underKm');
      });
      expect(find.text("Couldn't look that up"), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();
      expect(calls, hasLength(2));
      expect(find.text('Under a kilometre away'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('Check again waits out its cooldown', (tester) async {
      final calls = await pumpScreen(tester,
          respond: (_) => _status('underKm'));
      final check = find.ancestor(
          of: find.text('Check again'),
          matching: find.bySubtype<ButtonStyleButton>());
      expect(tester.widget<ButtonStyleButton>(check).onPressed, isNull);
      await tester.pump(kPostboxLinkRescanCooldown);
      await tester.pump();
      expect(tester.widget<ButtonStyleButton>(check).onPressed, isNotNull);
      await tester.tap(check);
      await tester.pump();
      await tester.pump();
      expect(calls, hasLength(2));
      await drain(tester);
    });
  });
}
