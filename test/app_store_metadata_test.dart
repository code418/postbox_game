import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Guards the App Store listing in fastlane/metadata/ios (deliver layout) and
/// the screenshot set in screenshots/marketing/appstore against App Store
/// Connect's limits, so a copy edit can't silently break submission.
void main() {
  const dir = 'fastlane/metadata/ios/en-GB';
  String read(String name) => File('$dir/$name.txt').readAsStringSync();

  // App Store Connect field limits, in characters.
  const limits = {
    'name': 30,
    'subtitle': 30,
    'promotional_text': 170,
    'keywords': 100,
    'description': 4000,
  };

  for (final entry in limits.entries) {
    test('${entry.key} is present and within ${entry.value} characters', () {
      final text = read(entry.key);
      expect(text.trim(), isNotEmpty);
      expect(text.length, lessThanOrEqualTo(entry.value));
      expect(text, equals(text.trim()),
          reason: 'stray whitespace counts toward the limit');
    });
  }

  test('keywords are comma-separated with no spaces or repeats', () {
    final keywords = read('keywords').split(',');
    expect(keywords.every((k) => k.isNotEmpty && k == k.trim()), isTrue,
        reason: 'spaces after commas waste the 100-character budget');
    expect(keywords.toSet().length, keywords.length);
  });

  test('keywords do not repeat words already indexed from name or subtitle',
      () {
    final indexed = '${read('name')} ${read('subtitle')}'
        .toLowerCase()
        .split(RegExp(r"[^a-z]+"))
        .where((w) => w.length > 2)
        .toSet();
    for (final keyword in read('keywords').split(',')) {
      for (final word in keyword.split(' ')) {
        expect(indexed, isNot(contains(word)), reason: '"$word" in keywords');
      }
    }
  });

  test('listing text names no other platform (guideline 2.3.10)', () {
    final text = [
      for (final name in [...limits.keys]) read(name),
      File('fastlane/metadata/ios/review_information/notes.txt')
          .readAsStringSync(),
    ].join('\n').toLowerCase();
    for (final banned in ['android', 'google play', 'play store', 'wear os']) {
      expect(text, isNot(contains(banned)), reason: banned);
    }
  });

  test('support and privacy URLs are https and served by the web build', () {
    for (final (name, page) in [
      ('support_url', 'web/support.html'),
      ('privacy_url', 'web/privacy-policy.html'),
    ]) {
      final url = read(name);
      expect(url, startsWith('https://'), reason: name);
      // Hosting uses cleanUrls, so /support serves web/support.html.
      expect(File(page).existsSync(), isTrue, reason: page);
    }
  });

  group('iPhone 6.9" screenshots', () {
    for (final theme in ['light', 'dark']) {
      test('$theme set: 1-10 PNGs at 1320x2868 without alpha', () {
        final shots = Directory('screenshots/marketing/appstore/iphone_6.9/$theme')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.png'))
            .toList();
        expect(shots.length, inInclusiveRange(1, 10));
        for (final shot in shots) {
          final header = ByteData.sublistView(shot.readAsBytesSync(), 0, 26);
          expect(header.getUint32(16), 1320, reason: shot.path);
          expect(header.getUint32(20), 2868, reason: shot.path);
          // IHDR colour type 2 = RGB; 6 (RGBA) is rejected by App Store Connect.
          expect(header.getUint8(25), 2, reason: '${shot.path} must be RGB');
        }
      });
    }
  });
}
