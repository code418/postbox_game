// "Offline — showing saved data" appeared while connected. Two causes, both
// pinned here:
// 1. The listeners feeding it used plain snapshots(): when the server
//    confirmed a cached copy WITHOUT changing it, only the metadata changed,
//    the listener was never told, and the chip stayed up until the data next
//    changed.
// 2. Even with that fixed, a listener's first snapshot comes from the cache
//    online too, so every cold start would flash the chip.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/widgets/stale_data_chip.dart';

const _text = 'Offline — showing saved data';

Widget _host(bool visible) =>
    MaterialApp(home: Scaffold(body: StaleDataChip(visible: visible)));

void main() {
  group('StaleDataChip', () {
    testWidgets('a cached first snapshot the server confirms never shows it',
        (tester) async {
      await tester.pumpWidget(_host(true)); // cached copy first
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(_text), findsNothing);

      await tester.pumpWidget(_host(false)); // server confirmation
      await tester.pump(StaleDataChip.defaultDelay);
      expect(find.text(_text), findsNothing);
    });

    testWidgets('data still from the cache after the grace period shows it',
        (tester) async {
      await tester.pumpWidget(_host(true));
      await tester.pump(StaleDataChip.defaultDelay);
      expect(find.text(_text), findsOneWidget);
    });

    testWidgets('it hides at once when the server data arrives',
        (tester) async {
      await tester.pumpWidget(_host(true));
      await tester.pump(StaleDataChip.defaultDelay);
      expect(find.text(_text), findsOneWidget);

      await tester.pumpWidget(_host(false));
      await tester.pump();
      expect(find.text(_text), findsNothing);
    });
  });

  test('every listener feeding the cache indicator subscribes to metadata',
      () {
    // A plain snapshots() never reports the cache → server transition when
    // the data is unchanged, so the indicator would stay on while online.
    final offenders = <String>[];
    for (final path in const [
      'lib/leaderboard_screen.dart',
      'lib/friends_screen.dart',
      'lib/wear/wear_leaderboard_page.dart',
    ]) {
      final src = File(path).readAsStringSync();
      expect(src, contains('isFromCache'),
          reason: '$path no longer reads isFromCache: update this list');
      if (!src.contains('snapshots(includeMetadataChanges: true)')) {
        offenders.add(path);
      }
    }
    // Any other file that starts reading isFromCache must be added above.
    final readers = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) =>
            f.path.endsWith('.dart') &&
            !f.path.endsWith('stale_data_chip.dart') && // documents it
            f.readAsStringSync().contains('metadata.isFromCache'))
        .map((f) => f.path)
        .toSet();
    expect(readers, {
      'lib/leaderboard_screen.dart',
      'lib/friends_screen.dart',
      'lib/wear/wear_leaderboard_page.dart',
    });
    expect(offenders, isEmpty);
  });
}
