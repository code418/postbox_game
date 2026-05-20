// Cross-language guard: the display-name profanity block-list and length bounds
// are duplicated in two source files, one per language, kept aligned only by
// "MUST match" / "keep in sync" comments:
//
//   - lib/validators.dart                  (_blockedWords, min/maxDisplayNameChars)
//   - functions/src/_profanityFilter.ts    (BLOCKED_WORDS, MIN/MAX_DISPLAY_NAME_CHARS)
//
// The Flutter form validator is the gate before the updateDisplayName callable
// runs the server-side check. If the two lists drift, a player can pick a name
// the client accepts but the server rejects (or vice versa) with no other test
// catching it. This test parses both source files and asserts they agree.
//
// It is a plain VM test (uses dart:io) — `flutter test` runs with the package
// root as the working directory, so the relative paths resolve.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Extracts the string literals from a `[ ... ]` array literal that follows
/// [anchor] in [source]. Handles both single- and double-quoted entries and
/// tolerates trailing commas / newlines / interleaved comments.
Set<String> _extractArrayLiterals(String source, String anchor) {
  final anchorIdx = source.indexOf(anchor);
  expect(anchorIdx, isNonNegative, reason: 'anchor not found: $anchor');
  final open = source.indexOf('[', anchorIdx);
  final close = source.indexOf(']', open);
  expect(open, isNonNegative, reason: 'no [ after anchor: $anchor');
  expect(close, greaterThan(open), reason: 'no ] after anchor: $anchor');
  final body = source.substring(open + 1, close);
  // Match 'word' or "word" — the block-list entries are all simple lowercase
  // ASCII with no embedded quotes, so a non-greedy quoted-run match is enough.
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
  late String dartSrc;
  late String tsSrc;

  setUpAll(() {
    dartSrc = File('lib/validators.dart').readAsStringSync();
    tsSrc = File('functions/src/_profanityFilter.ts').readAsStringSync();
  });

  group('profanity block-list stays in sync across languages', () {
    test('Dart _blockedWords == TS BLOCKED_WORDS', () {
      final dartWords = _extractArrayLiterals(dartSrc, '_blockedWords');
      final tsWords = _extractArrayLiterals(tsSrc, 'BLOCKED_WORDS');

      // Sanity: parsing actually found a list (guards against a future refactor
      // that renames the constant and silently makes this test vacuous).
      expect(dartWords.length, greaterThan(10),
          reason: 'parsed too few Dart block-words — extraction likely broke');
      expect(tsWords.length, greaterThan(10),
          reason: 'parsed too few TS block-words — extraction likely broke');

      final onlyInDart = dartWords.difference(tsWords);
      final onlyInTs = tsWords.difference(dartWords);
      expect(
        onlyInDart,
        isEmpty,
        reason: 'words in lib/validators.dart but missing from '
            'functions/src/_profanityFilter.ts: $onlyInDart',
      );
      expect(
        onlyInTs,
        isEmpty,
        reason: 'words in functions/src/_profanityFilter.ts but missing from '
            'lib/validators.dart: $onlyInTs',
      );
    });
  });

  group('display-name length bounds stay in sync', () {
    test('min length matches', () {
      expect(
        _extractIntConst(dartSrc, 'minDisplayNameChars'),
        equals(_extractIntConst(tsSrc, 'MIN_DISPLAY_NAME_CHARS')),
      );
    });

    test('max length matches', () {
      expect(
        _extractIntConst(dartSrc, 'maxDisplayNameChars'),
        equals(_extractIntConst(tsSrc, 'MAX_DISPLAY_NAME_CHARS')),
      );
    });
  });
}
