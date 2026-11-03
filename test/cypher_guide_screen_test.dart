// The Cypher guide: every cypher with its artwork, name, reign and points,
// in reign or points order, with points following Remote Config.

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/cypher_guide_screen.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/remote_config_service.dart';
import 'package:postbox_game/widgets/cypher_art.dart';

class _StubRemoteConfig extends Fake implements FirebaseRemoteConfig {
  _StubRemoteConfig({this.pointsJson = ''});

  final String pointsJson;

  @override
  bool getBool(String key) => false;
  @override
  String getString(String key) =>
      key == RemoteConfigService.keyPointsByMonarch ? pointsJson : '';
  @override
  double getDouble(String key) => 0.0;
  @override
  int getInt(String key) => 0;
}

Finder _card(String code) => find.byKey(ValueKey('cypher-guide-$code'));

Future<void> _pumpGuide(WidgetTester tester) async {
  // Tall enough that the ListView builds every card.
  tester.view.physicalSize = const Size(420, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const MaterialApp(home: CypherGuideScreen()));
}

void main() {
  setUp(() {
    RemoteConfigService.instance =
        RemoteConfigService(remoteConfig: _StubRemoteConfig());
  });
  tearDown(RemoteConfigService.resetForTest);

  testWidgets('one card per cypher plus plain, each with plate and points',
      (tester) async {
    await _pumpGuide(tester);
    expect(find.byType(CypherGuideCard),
        findsNWidgets(MonarchInfo.all.length + 1));
    for (final code in [...MonarchInfo.all, MonarchInfo.plainKey]) {
      final card = _card(code);
      expect(card, findsOneWidget, reason: code);
      expect(
          find.descendant(
              of: card,
              matching: find.byWidgetPredicate(
                  (w) => w is CypherPlate && w.code == code)),
          findsOneWidget);
      expect(
          find.descendant(
              of: card, matching: find.text(MonarchInfo.nameOf(code))),
          findsOneWidget);
      expect(
          find.descendant(
              of: card,
              matching: find.text('${MonarchInfo.getPoints(code)} pts')),
          findsOneWidget,
          reason: '$code points');
    }
    expect(find.text(CypherGuideCard.plainLookFor), findsOneWidget);
    expect(find.text(MonarchInfo.lookFor['EIIR']!), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reign order by default, highest points first on request',
      (tester) async {
    await _pumpGuide(tester);
    List<String> onScreenOrder() {
      final codes = List.of(MonarchInfo.all);
      codes.sort((a, b) => tester
          .getTopLeft(_card(a))
          .dy
          .compareTo(tester.getTopLeft(_card(b)).dy));
      return codes;
    }

    expect(onScreenOrder(), MonarchInfo.reignOrder);

    await tester.tap(find.text('By points'));
    await tester.pumpAndSettle();
    final byPoints = onScreenOrder();
    final points = byPoints.map(MonarchInfo.getPoints).toList();
    expect(points, List.of(points)..sort((a, b) => b - a));
    expect(byPoints.first, 'EVIIIR');
    // Plain stays last in either order.
    expect(tester.getTopLeft(_card(MonarchInfo.plainKey)).dy,
        greaterThan(tester.getTopLeft(_card(byPoints.last)).dy));
  });

  testWidgets('points follow the Remote Config override', (tester) async {
    RemoteConfigService.instance = RemoteConfigService(
        remoteConfig: _StubRemoteConfig(pointsJson: '{"EIIR": 3}'));
    await _pumpGuide(tester);
    expect(find.descendant(of: _card('EIIR'), matching: find.text('3 pts')),
        findsOneWidget);
  });

  test('orderedCodes keeps reign order for equal points', () {
    final ordered = CypherGuideScreen.orderedCodes(
        CypherGuideSort.points, MonarchInfo.getPoints);
    // GVR, GR, GVIR and SCOTTISH_CROWN all score 4: they keep reign order.
    final fours = ordered.where((c) => MonarchInfo.getPoints(c) == 4).toList();
    expect(fours, ['GVR', 'GR', 'GVIR', 'SCOTTISH_CROWN']);
    expect(CypherGuideScreen.orderedCodes(
            CypherGuideSort.reign, MonarchInfo.getPoints),
        MonarchInfo.reignOrder);
  });

  testWidgets('large text in dark mode lays out without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(360, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: MediaQuery.withClampedTextScaling(
        minScaleFactor: 1.4,
        maxScaleFactor: 1.4,
        child: const CypherGuideScreen(),
      ),
    ));
    expect(tester.takeException(), isNull);
  });
}
