// Cross-language guards for constants that are hand-duplicated across the
// Flutter (Dart), Cloud Functions (TypeScript), and importer (JavaScript)
// sources, kept aligned only by "MUST match" / "keep in sync" comments. Each
// pair/triple below is parsed straight from source and asserted equal so a
// drift fails CI instead of silently shipping mismatched behaviour:
//
//   1. Display-name profanity block-list + length bounds
//        - lib/validators.dart                (_blockedWords, min/maxDisplayNameChars)
//        - functions/src/_profanityFilter.ts  (BLOCKED_WORDS, MIN/MAX_DISPLAY_NAME_CHARS)
//      The Flutter validator is the gate before the updateDisplayName callable
//      re-checks server-side; a drift lets a player pick a name the client
//      accepts but the server rejects (or vice versa).
//
//   2. Recognised royal-cypher (monarch) key-set, duplicated THREE ways
//        - lib/monarch_info.dart              (MonarchInfo.all)
//        - functions/src/_getPoints.ts        (KNOWN_MONARCHS)
//        - functions/import_postboxes.js      (VALID_CIPHERS)
//      A monarch added to one but not the others would, e.g., import boxes the
//      client can't render in the quiz pool, or score a cypher the server
//      doesn't recognise. The per-value getPoints tests on each side pin the
//      *values* but nothing currently cross-checks the *key-set*.
//
// Plain VM tests (use dart:io) — `flutter test` runs with the package root as
// the working directory, so the relative paths resolve.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Extracts the string literals from the first `[ ... ]` array literal that
/// follows [anchor] in [source]. Handles both single- and double-quoted entries
/// and tolerates trailing commas / newlines / interleaved comments.
Set<String> _extractArrayLiterals(String source, String anchor) {
  final anchorIdx = source.indexOf(anchor);
  expect(anchorIdx, isNonNegative, reason: 'anchor not found: $anchor');
  final open = source.indexOf('[', anchorIdx);
  final close = source.indexOf(']', open);
  expect(open, isNonNegative, reason: 'no [ after anchor: $anchor');
  expect(close, greaterThan(open), reason: 'no ] after anchor: $anchor');
  final body = source.substring(open + 1, close);
  // Match 'word' or "word" — these constants are all simple ASCII with no
  // embedded quotes, so a non-greedy quoted-run match is enough.
  final re = RegExp(r'''(['"])([^'"]+)\1''');
  return re.allMatches(body).map((m) => m.group(2)!).toSet();
}

/// Extracts the integer assigned to the first `<name> = <int>` occurrence.
int _extractIntConst(String source, String name) {
  final re = RegExp('$name\\s*=\\s*(\\d+)');
  final m = re.firstMatch(source);
  expect(m, isNotNull, reason: 'int const not found: $name');
  return int.parse(m!.group(1)!);
}

void main() {
  late String validatorsDart;
  late String profanityTs;
  late String monarchInfoDart;
  late String getPointsTs;
  late String importJs;

  setUpAll(() {
    validatorsDart = File('lib/validators.dart').readAsStringSync();
    profanityTs = File('functions/src/_profanityFilter.ts').readAsStringSync();
    monarchInfoDart = File('lib/monarch_info.dart').readAsStringSync();
    getPointsTs = File('functions/src/_getPoints.ts').readAsStringSync();
    importJs = File('functions/import_postboxes.js').readAsStringSync();
  });

  group('profanity block-list stays in sync across languages', () {
    test('Dart _blockedWords == TS BLOCKED_WORDS', () {
      final dartWords = _extractArrayLiterals(validatorsDart, '_blockedWords');
      final tsWords = _extractArrayLiterals(profanityTs, 'BLOCKED_WORDS');

      // Sanity: parsing actually found a list (guards against a future refactor
      // that renames the constant and silently makes this test vacuous).
      expect(dartWords.length, greaterThan(10),
          reason: 'parsed too few Dart block-words — extraction likely broke');
      expect(tsWords.length, greaterThan(10),
          reason: 'parsed too few TS block-words — extraction likely broke');

      final onlyInDart = dartWords.difference(tsWords);
      final onlyInTs = tsWords.difference(dartWords);
      expect(onlyInDart, isEmpty,
          reason: 'words in lib/validators.dart but missing from '
              'functions/src/_profanityFilter.ts: $onlyInDart');
      expect(onlyInTs, isEmpty,
          reason: 'words in functions/src/_profanityFilter.ts but missing from '
              'lib/validators.dart: $onlyInTs');
    });
  });

  group('display-name length bounds stay in sync', () {
    test('min length matches', () {
      expect(
        _extractIntConst(validatorsDart, 'minDisplayNameChars'),
        equals(_extractIntConst(profanityTs, 'MIN_DISPLAY_NAME_CHARS')),
      );
    });

    test('max length matches', () {
      expect(
        _extractIntConst(validatorsDart, 'maxDisplayNameChars'),
        equals(_extractIntConst(profanityTs, 'MAX_DISPLAY_NAME_CHARS')),
      );
    });
  });

  group('recognised monarch key-set stays in sync across all three sources', () {
    test('MonarchInfo.all == KNOWN_MONARCHS == VALID_CIPHERS', () {
      final clientSet =
          _extractArrayLiterals(monarchInfoDart, 'List<String> all');
      final serverSet = _extractArrayLiterals(getPointsTs, 'KNOWN_MONARCHS');
      // VALID_CIPHERS is a `new Set([ ... ])` — the array literal sits inside
      // the Set() call, so the first `[` after the anchor is still its open.
      final importerSet = _extractArrayLiterals(importJs, 'VALID_CIPHERS');

      // Sanity guards against an extraction that silently parsed nothing.
      expect(clientSet.length, greaterThan(5),
          reason: 'parsed too few client monarchs — extraction likely broke');
      expect(serverSet.length, greaterThan(5),
          reason: 'parsed too few server monarchs — extraction likely broke');
      expect(importerSet.length, greaterThan(5),
          reason: 'parsed too few importer monarchs — extraction likely broke');

      expect(serverSet, equals(clientSet),
          reason: 'KNOWN_MONARCHS (functions/src/_getPoints.ts) differs from '
              'MonarchInfo.all (lib/monarch_info.dart). '
              'only-in-server=${serverSet.difference(clientSet)} '
              'only-in-client=${clientSet.difference(serverSet)}');
      expect(importerSet, equals(clientSet),
          reason: 'VALID_CIPHERS (functions/import_postboxes.js) differs from '
              'MonarchInfo.all (lib/monarch_info.dart). '
              'only-in-importer=${importerSet.difference(clientSet)} '
              'only-in-client=${clientSet.difference(importerSet)}');
    });
  });
}
