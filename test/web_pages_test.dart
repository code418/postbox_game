import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/monarch_info.dart';

/// Pins every hosted page in web/ except the Flutter shell (web/index.html),
/// plus the crawler files beside them (robots.txt, sitemap.xml, llms.txt).
/// The pages are styled by web/site.css, which Tailwind builds from
/// web_styles/ by scanning the same set of files; see web_styles/README.md.
/// A new page is picked up here, and by the CSS build, with no list to update.
void main() {
  const origin = 'https://the-postbox-game.web.app';

  // HTML documents only: web/ also holds non-HTML .html files, such as the
  // Search Console verification token (google<hex>.html).
  final pages = <String, String>{};
  for (final file in Directory('web').listSync().whereType<File>()) {
    final name = file.uri.pathSegments.last;
    if (!name.endsWith('.html') || name == 'index.html') continue;
    final html = file.readAsStringSync();
    if (!html.trimLeft().toLowerCase().startsWith('<!doctype html')) continue;
    pages[name] = html;
  }

  bool isNoindex(String html) =>
      RegExp(r'<meta name="robots" content="[^"]*noindex').hasMatch(html);

  final sitemapLocs = RegExp(r'<loc>([^<]+)</loc>')
      .allMatches(File('web/sitemap.xml').readAsStringSync())
      .map((m) => m.group(1)!)
      .toSet();

  test('finds the hosted pages', () {
    expect(
        pages.keys,
        containsAll([
          'get.html',
          'invite.html',
          'support.html',
          'privacy-policy.html',
          'data-safety.html',
          '404.html',
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
    // Root-absolute because /invite/** rewrites to invite.html and 404.html
    // is served at any depth, so a relative path would resolve elsewhere.
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

  test('invite and not-found pages stay out of search indexes', () {
    // An indexed invite URL would publish the inviter's code, letting
    // strangers add them as a friend.
    expect(isNoindex(pages['invite.html']!), isTrue);
    expect(isNoindex(pages['404.html']!), isTrue);
  });

  test('the sitemap lists every indexable page at its canonical URL', () {
    final expected = <String>{};
    for (final MapEntry(key: name, value: html) in pages.entries) {
      if (isNoindex(html)) continue;
      final canonical = RegExp(r'<link rel="canonical" href="([^"]+)">')
          .firstMatch(html)
          ?.group(1);
      expect(canonical, '$origin/${name.replaceAll('.html', '')}',
          reason: '$name needs a canonical link to its clean URL');
      expected.add(canonical!);
    }
    expect(sitemapLocs, expected,
        reason: 'web/sitemap.xml must list exactly the indexable pages');
  });

  test('robots.txt allows crawling, declares content signals and names the '
      'sitemap', () {
    final robots = File('web/robots.txt').readAsStringSync();
    expect(robots, contains('Sitemap: $origin/sitemap.xml'));
    // A crawler reads only the most specific group naming it (RFC 9309), so
    // each group must carry the whole policy.
    final groups = robots
        .split(RegExp(r'\n\s*\n'))
        .where((chunk) =>
            RegExp(r'^User-agent:', multiLine: true).hasMatch(chunk))
        .toList();
    expect(groups, isNotEmpty);
    expect(groups.first, contains('User-agent: *'));
    for (final group in groups) {
      expect(group, contains('Content-Signal: '), reason: group);
      expect(group, contains('Allow: /'), reason: group);
      // Crawlers must reach the invite page to see its noindex.
      expect(group, isNot(contains('Disallow: /invite')), reason: group);
    }
  });

  test('llms.txt summarises the game with live points and links every page',
      () {
    final llms = File('web/llms.txt').readAsStringSync();
    expect(llms, startsWith('# The Postbox Game\n'));
    expect(llms, contains(RegExp(r'^> \S', multiLine: true)));
    for (final loc in sitemapLocs) {
      expect(llms, contains('($loc)'), reason: loc);
    }
    final listed = {
      for (final m in RegExp(r'^- ([A-Z_]+) \([^)]*\): (\d+) points$',
              multiLine: true)
          .allMatches(llms))
        m.group(1)!: int.parse(m.group(2)!),
    };
    expect(listed, MonarchInfo.points);
  });

  test('crawler files never name the guide character', () {
    for (final path in ['web/robots.txt', 'web/sitemap.xml', 'web/llms.txt']) {
      expect(File(path).readAsStringSync(),
          isNot(matches(RegExp('james', caseSensitive: false))),
          reason: path);
    }
  });

  test('only extensionless paths fall back to the app, so unknown files 404',
      () {
    // A catch-all "**" rewrite answered every unknown path, robots.txt and
    // /.well-known/* included, with the Flutter shell and a 200.
    final hosting = (jsonDecode(File('firebase.json').readAsStringSync())
        as Map<String, dynamic>)['hosting'] as Map<String, dynamic>;
    final rewrites =
        (hosting['rewrites'] as List).cast<Map<String, dynamic>>();
    expect(rewrites.where((r) => r['source'] == '**'), isEmpty);
    final toApp =
        rewrites.where((r) => r['destination'] == '/index.html').toList();
    expect(toApp, hasLength(1));
    final fallback = RegExp(toApp.single['regex'] as String);
    for (final path in ['/', '/nearby', '/claim']) {
      expect(fallback.hasMatch(path), isTrue, reason: path);
    }
    for (final path in ['/robots.txt', '/auth.md', '/.well-known/x', '/a.php']) {
      expect(fallback.hasMatch(path), isFalse, reason: path);
    }
  });
}
