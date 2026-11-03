// The royal cypher artwork (assets/cyphers/, drawn by
// tool/cypher_art/build_cypher_svgs.py) and the widgets that show it.
//
// The SVGs are rendered by flutter_svg on the phone AND the Wear OS watch,
// so they must stay within what it draws faithfully: paths only, no <text>
// (the watch has no Playfair Display), no raster <image>, filters or masks.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/wear/wear_labels.dart';
import 'package:postbox_game/widgets/cypher_art.dart';

void main() {
  group('cypher assets', () {
    test('every quiz cypher has artwork, plain has none', () {
      for (final code in MonarchInfo.all) {
        final asset = CypherArt.assetFor(code);
        expect(asset, isNotNull, reason: '$code has no artwork');
        expect(File(asset!).existsSync(), isTrue,
            reason: '$asset is missing: rerun build_cypher_svgs.py');
      }
      expect(CypherArt.assetFor(MonarchInfo.plainKey), isNull);
      expect(CypherArt.assetFor('NOT_A_CYPHER'), isNull);
    });

    test('pubspec bundles assets/cyphers/', () {
      expect(File('pubspec.yaml').readAsStringSync(),
          contains('    - assets/cyphers/\n'));
    });

    test('no stray files in assets/cyphers/', () {
      // The whole directory is bundled into both the phone and watch apps.
      final expected =
          MonarchInfo.all.map((c) => '${c.toLowerCase()}.svg').toSet();
      final actual = Directory('assets/cyphers')
          .listSync()
          .map((e) => e.uri.pathSegments.last)
          .toSet();
      expect(actual, expected);
    });

    for (final code in MonarchInfo.all) {
      test('$code: shared viewBox, paths only', () {
        final svg = File(CypherArt.assetFor(code)!).readAsStringSync();
        expect(svg, contains('viewBox="0 0 200 160"'));
        for (final banned in ['<text', '<image', '<filter', '<mask', 'url(']) {
          expect(svg.contains(banned), isFalse,
              reason: '$code uses $banned, which the watch cannot draw '
                  'faithfully');
        }
        expect(svg, contains('<path'));
      });

      testWidgets('$code: flutter_svg parses it', (tester) async {
        final svg = File(CypherArt.assetFor(code)!).readAsStringSync();
        final info = await tester.runAsync(
            () => vg.loadPicture(SvgStringLoader(svg), null));
        expect(info, isNotNull);
        expect(info!.size, const Size(200, 160));
        info.picture.dispose();
      });
    }
  });

  group('MonarchInfo name/detail', () {
    test('splits the label into name and bracketed detail', () {
      expect(MonarchInfo.nameOf('EIIR'), 'Elizabeth II');
      expect(MonarchInfo.detailOf('EIIR'), '1952–2022');
      expect(MonarchInfo.nameOf('SCOTTISH_CROWN'), 'Scottish Crown');
      expect(MonarchInfo.detailOf('SCOTTISH_CROWN'), 'Scotland only');
      expect(MonarchInfo.nameOf('GR'), 'George');
      expect(MonarchInfo.detailOf('GR'), 'V or VI');
    });

    test('labels without brackets, and unknown codes', () {
      expect(MonarchInfo.nameOf(MonarchInfo.plainKey), 'Plain / no cypher');
      expect(MonarchInfo.detailOf(MonarchInfo.plainKey), isNull);
      expect(MonarchInfo.nameOf('XYZ'), 'XYZ');
      expect(MonarchInfo.detailOf('XYZ'), isNull);
    });

    test('every quiz cypher has a name and a detail', () {
      for (final code in MonarchInfo.all) {
        expect(MonarchInfo.nameOf(code), isNot(contains('(')), reason: code);
        expect(MonarchInfo.detailOf(code), isNotNull, reason: code);
      }
    });

    test('the watch label is the name', () {
      for (final code in MonarchInfo.all) {
        expect(watchMonarchLabel(code), MonarchInfo.nameOf(code));
      }
    });

    test('lookFor and reignOrder cover exactly MonarchInfo.all', () {
      expect(MonarchInfo.lookFor.keys.toSet(), MonarchInfo.all.toSet());
      expect(MonarchInfo.reignOrder.toSet(), MonarchInfo.all.toSet());
      expect(MonarchInfo.reignOrder.length, MonarchInfo.all.length);
    });
  });

  group('widgets', () {
    testWidgets('CypherPlate draws the art for a cypher and a dash for plain',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Column(children: [
            CypherPlate('EIIR', height: 80, width: 100),
            CypherPlate(MonarchInfo.plainKey, height: 80, width: 100),
          ]),
        ),
      ));
      // Embossed: the shadow copy plus the cream copy.
      expect(
          find.descendant(
              of: find.byType(CypherPlate).first,
              matching: find.byType(SvgPicture)),
          findsNWidgets(2));
      expect(find.text('—'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the plate is decorative: no semantics of its own',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: CypherPlate(MonarchInfo.plainKey, width: 100)),
      ));
      expect(find.bySemanticsLabel('—'), findsNothing);
      handle.dispose();
    });

    testWidgets('CypherArt keeps the artwork aspect ratio', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Center(child: CypherArt('VR', height: 40)),
      ));
      expect(tester.getSize(find.byType(CypherArt)), const Size(50, 40));
    });
  });
}
