import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/friends_screen.dart';

void main() {
  group('namesFromLookup', () {
    test('resolves the names the lookup found', () {
      expect(
        namesFromLookup(['a', 'b'], {'a': 'Alice', 'b': null},
            fromCache: false),
        {'a': 'Alice', 'b': ''},
      );
    });

    test('a uid the server did not return is a deleted account', () {
      expect(namesFromLookup(['a', 'gone'], {'a': 'Alice'}, fromCache: false),
          {'a': 'Alice', 'gone': ''});
    });

    test('a uid missing from a CACHE answer stays unresolved', () {
      // Offline, the query answers from the local cache without throwing. A
      // friend who just isn't cached yet must not be labelled deleted.
      final names =
          namesFromLookup(['a', 'uncached'], {'a': 'Alice'}, fromCache: true);
      expect(names, {'a': 'Alice'});
      expect(names.containsKey('uncached'), isFalse);
    });
  });
}
