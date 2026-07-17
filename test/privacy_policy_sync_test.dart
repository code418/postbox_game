import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the two privacy-policy surfaces against each other so they can't
/// drift: assets/legal/privacy_policy.md (rendered in-app) and
/// web/privacy-policy.html (hosted at /privacy-policy, linked from the Play
/// listing). Same idea as test/cross_language_sync_test.dart.
void main() {
  final md = File('assets/legal/privacy_policy.md').readAsStringSync();
  final html = File('web/privacy-policy.html').readAsStringSync();

  List<String> mdHeadings() => RegExp(r'^## (.+)$', multiLine: true)
      .allMatches(md)
      .map((m) => m.group(1)!.trim())
      .toList();

  List<String> htmlHeadings() => RegExp(r'<h2>(.+?)</h2>')
      .allMatches(html)
      .map((m) => m.group(1)!.trim())
      .toList();

  test('section headings match, in order', () {
    final fromMd = mdHeadings();
    final fromHtml = htmlHeadings();
    expect(fromMd, isNotEmpty);
    expect(fromMd, equals(fromHtml),
        reason: 'assets/legal/privacy_policy.md and web/privacy-policy.html '
            'must carry identical sections — update both together');
  });

  test('Last updated stamps match', () {
    final mdStamp =
        RegExp(r'Last updated: ([^_\n]+)').firstMatch(md)?.group(1)?.trim();
    final htmlStamp =
        RegExp(r'Last updated: ([^<\n]+)').firstMatch(html)?.group(1)?.trim();
    expect(mdStamp, isNotNull);
    expect(mdStamp, equals(htmlStamp));
  });

  test('both documents describe the retention windows', () {
    for (final doc in [md, html]) {
      expect(doc, contains('90 days'));
      expect(doc, contains('30 days'));
      expect(doc, contains('180 days'));
    }
  });
}
