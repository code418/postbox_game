import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins every hosted page in web/ except the Flutter shell (web/index.html).
/// They are styled by web/site.css, which Tailwind builds from web_styles/
/// by scanning the same set of files; see web_styles/README.md. A new page
/// is picked up here, and by the CSS build, with no list to update.
void main() {
  final pages = {
    for (final file in Directory('web')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.html'))
        .where((f) => f.uri.pathSegments.last != 'index.html'))
      file.uri.pathSegments.last: file.readAsStringSync(),
  };

  test('finds the hosted pages', () {
    expect(
        pages.keys,
        containsAll([
          'get.html',
          'invite.html',
          'support.html',
          'privacy-policy.html',
          'data-safety.html',
        ]));
  });

  Iterable<String> attributeValues(String html, String attribute) =>
      RegExp('$attribute="([^"]*)"')
          .allMatches(html)
          .map((m) => m.group(1)!);

  test('every page loads the compiled stylesheet', () {
    expect(File('web/site.css').existsSync(), isTrue,
        reason: 'run npm run build in web_styles/');
    for (final MapEntry(key: name, value: html) in pages.entries) {
      expect(html, contains('<link rel="stylesheet" href="/site.css">'),
          reason: name);
    }
  });

  test('no page loads anything from another site', () {
    // Fonts, icons and badges are self-hosted, so viewing a page tells no
    // third party (font CDNs included) about the visitor. The privacy policy
    // only discloses Firebase, Apple and Nominatim. Plain links are fine.
    for (final MapEntry(key: name, value: html) in pages.entries) {
      final loaded = [
        ...attributeValues(html, 'src'),
        ...attributeValues(html, 'srcset'),
        ...RegExp(r'<link\b[^>]*>')
            .allMatches(html)
            .map((m) => m.group(0)!)
            .where((tag) => !tag.contains('rel="canonical"'))
            .expand((tag) => attributeValues(tag, 'href')),
      ];
      for (final url in loaded) {
        expect(url, isNot(matches(RegExp(r'^(https?:)?//'))),
            reason: '$name loads $url');
      }
    }
  });

  test('local assets exist and are root-absolute', () {
    // Root-absolute because /invite/** rewrites to invite.html, so a relative
    // path would resolve under /invite/ and fetch the page instead.
    for (final MapEntry(key: name, value: html) in pages.entries) {
      final local = [
        ...attributeValues(html, 'src'),
        ...attributeValues(html, 'srcset'),
        ...RegExp(r'<link\b[^>]*>')
            .allMatches(html)
            .map((m) => m.group(0)!)
            .where((tag) => !tag.contains('rel="canonical"'))
            .expand((tag) => attributeValues(tag, 'href')),
      ];
      expect(local, isNotEmpty, reason: name);
      for (final path in local) {
        expect(path, startsWith('/'), reason: '$name: $path');
        expect(File('web$path').existsSync(), isTrue, reason: '$name: $path');
      }
    }
  });

  test('every icon a page uses is in the sprite', () {
    final sprite = File('web/icons.svg').readAsStringSync();
    final ids = RegExp(r'<symbol id="([^"]+)"')
        .allMatches(sprite)
        .map((m) => m.group(1)!)
        .toSet();
    for (final MapEntry(key: name, value: html) in pages.entries) {
      for (final match
          in RegExp(r'href="/icons\.svg#([^"]+)"').allMatches(html)) {
        expect(ids, contains(match.group(1)), reason: name);
      }
    }
  });
}
