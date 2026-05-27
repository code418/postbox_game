import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsFlag;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/widgets/postbox_marker.dart';

/// Pins the screen-reader labels emitted by [postboxMarker]. Without these
/// the marker is invisible to TalkBack/VoiceOver — a regression here would
/// silently break the map view of the history and heatmap screens for users
/// with assistive tech.

const _point = LatLng(51.5074, -0.1278);

Future<String> _labelFor(WidgetTester tester, Marker marker) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(child: marker.child),
      ),
    ),
  );
  // Find the marker's Semantics node. Walk up from any descendant so a
  // future wrapper layer (e.g. Tooltip) doesn't break the lookup.
  final semantics = tester.getSemantics(find.byType(GestureDetector));
  return semantics.label;
}

void main() {
  group('postboxMarker semantics label', () {
    testWidgets('unclaimed, unknown cipher → "Postbox"', (tester) async {
      final marker = postboxMarker(_point);
      expect(await _labelFor(tester, marker), 'Postbox');
    });

    testWidgets('unclaimed, common cipher → "Postbox, <era>"', (tester) async {
      final marker = postboxMarker(_point, cipher: 'EIIR');
      expect(await _labelFor(tester, marker),
          equals('Postbox, Elizabeth II (1952–2022)'));
    });

    testWidgets('rare cipher reads "rare"', (tester) async {
      // EVIIIR (Edward VIII) is in MonarchInfo.rareCiphers; the badge is
      // suppressed when claimed, and the label follows the badge.
      final marker = postboxMarker(_point, cipher: 'EVIIIR');
      expect(await _labelFor(tester, marker), contains('rare'));
    });

    testWidgets('historic cipher reads "historic"', (tester) async {
      // VR (Victoria) is in MonarchInfo.historicCiphers.
      final marker = postboxMarker(_point, cipher: 'VR');
      expect(await _labelFor(tester, marker), contains('historic'));
    });

    testWidgets('claimed flag adds "claimed" and suppresses rare/historic',
        (tester) async {
      // Claimed + rare cipher: the claimed checkmark replaces the rare
      // badge visually (single top-right slot). The label mirrors that so
      // it doesn't promise a rare-badge that isn't drawn.
      final marker = postboxMarker(_point, cipher: 'VR', claimed: true);
      final label = await _labelFor(tester, marker);
      expect(label, contains('claimed'));
      expect(label, isNot(contains('historic')));
    });

    testWidgets('button: true only when onTap is wired', (tester) async {
      final tappable = postboxMarker(_point, onTap: () {});
      final passive = postboxMarker(_point);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [tappable.child, passive.child]),
        ),
      ));

      final gestures = find.byType(GestureDetector);
      expect(gestures, findsNWidgets(2));
      final tappableSemantics = tester.getSemantics(gestures.first);
      final passiveSemantics = tester.getSemantics(gestures.last);
      expect(tappableSemantics.hasFlag(SemanticsFlag.isButton), isTrue);
      expect(passiveSemantics.hasFlag(SemanticsFlag.isButton), isFalse);
    });
  });
}
