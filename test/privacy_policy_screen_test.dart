import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/legal/privacy_policy_screen.dart';

const _sample = '''
# Sample Policy

_Last updated: July 2026_

First paragraph spanning
two source lines.

## 1. Section One

- **Bold lead:** bullet one
- bullet two

Closing paragraph.
''';

void main() {
  group('parsePolicyBlocks', () {
    test('maps title, headings, bullets, and paragraphs in order', () {
      final blocks = parsePolicyBlocks(_sample);
      expect(blocks.map((b) => b.type).toList(), [
        PolicyBlockType.title,
        PolicyBlockType.paragraph, // last-updated line
        PolicyBlockType.paragraph,
        PolicyBlockType.heading,
        PolicyBlockType.bullet,
        PolicyBlockType.bullet,
        PolicyBlockType.paragraph,
      ]);
      expect(blocks.first.text, 'Sample Policy');
      expect(blocks[3].text, '1. Section One');
    });

    test('joins wrapped paragraph lines and strips ** and _ markers', () {
      final blocks = parsePolicyBlocks(_sample);
      expect(blocks[2].text, 'First paragraph spanning two source lines.');
      expect(blocks[1].text, 'Last updated: July 2026');
      expect(blocks[4].text, 'Bold lead: bullet one');
    });

    test('parses the real bundled policy into a sane document', () {
      // Guards the asset itself: a malformed edit that breaks parsing fails here.
      final real =
          File('assets/legal/privacy_policy.md').readAsStringSync();
      final blocks = parsePolicyBlocks(real);
      expect(blocks.first.type, PolicyBlockType.title);
      expect(
        blocks.where((b) => b.type == PolicyBlockType.heading).length,
        greaterThanOrEqualTo(10),
      );
    });
  });

  group('PrivacyPolicyScreen', () {
    testWidgets('renders the parsed document without overflow', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: PrivacyPolicyScreen(markdownOverride: _sample),
      ));
      await tester.pump();
      expect(find.text('Sample Policy'), findsOneWidget);
      expect(find.text('1. Section One'), findsOneWidget);
      expect(find.textContaining('bullet two'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders in landscape without overflow', (tester) async {
      tester.view.physicalSize = const Size(1600, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(
        home: PrivacyPolicyScreen(markdownOverride: _sample),
      ));
      await tester.pump();
      expect(find.text('Sample Policy'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
