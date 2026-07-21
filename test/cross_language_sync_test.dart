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
//   3. Problem-report caps: max photos, max note length, max reference length
//        - lib/reports/report_repository.dart (maxPhotos, maxNoteChars, maxReferenceChars)
//        - functions/src/reports.ts           (MAX_PHOTOS, NOTE_MAX, REFERENCE_MAX)
//      Each pair is annotated "MUST match" in the source, but a numeric drift
//      between the client-side gate and the server-side validator silently
//      leaves users hitting "submission failed" only after the upload (e.g.
//      they pick 4 photos because client said `maxPhotos == 4`, server then
//      rejects). Asserted equal here so the comment can't go stale.
//
// Plain VM tests (use dart:io) — `flutter test` runs with the package root as
// the working directory, so the relative paths resolve.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/app_preferences.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/remote_config_service.dart';

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

/// Parses a Dart `{ 'KEY': N, ... }` int-valued map literal that follows
/// [anchor] into a `Map<String,int>`. Reads up to the closing `};`.
Map<String, int> _parseDartIntMap(String source, String anchor) {
  final idx = source.indexOf(anchor);
  expect(idx, isNonNegative, reason: 'anchor not found: $anchor');
  final open = source.indexOf('{', idx);
  final close = source.indexOf('};', open);
  expect(open, isNonNegative, reason: 'no { after anchor: $anchor');
  expect(close, greaterThan(open), reason: 'no }; after anchor: $anchor');
  final body = source.substring(open + 1, close);
  final re = RegExp(r'''['"]([^'"]+)['"]\s*:\s*(\d+)''');
  final out = <String, int>{};
  for (final m in re.allMatches(body)) {
    out[m.group(1)!] = int.parse(m.group(2)!);
  }
  return out;
}

/// Parses the `getPoints` switch in _getPoints.ts into a cipher→points map plus
/// the `default:` value. Handles fall-through `case` groups (several cases
/// sharing one `return`). Returns `(explicitCases, defaultValue)`.
({Map<String, int> cases, int defaultValue}) _parseTsGetPoints(String source) {
  final fnIdx = source.indexOf('function getPoints');
  expect(fnIdx, isNonNegative, reason: 'getPoints not found in _getPoints.ts');
  // Bound the scan to the function body (ends at the next top-level export).
  final endIdx = source.indexOf('KNOWN_MONARCHS', fnIdx);
  final body =
      source.substring(fnIdx, endIdx > fnIdx ? endIdx : source.length);

  final tokenRe =
      RegExp(r'case\s+"([^"]+)"\s*:|default\s*:|return\s+(\d+)\s*;');
  final pending = <String>[];
  final cases = <String, int>{};
  var inDefault = false;
  var defaultValue = -1;
  for (final m in tokenRe.allMatches(body)) {
    final caseKey = m.group(1);
    final returnVal = m.group(2);
    if (caseKey != null) {
      pending.add(caseKey);
    } else if (returnVal != null) {
      final v = int.parse(returnVal);
      if (inDefault) {
        defaultValue = v;
        inDefault = false;
      } else {
        for (final k in pending) {
          cases[k] = v;
        }
        pending.clear();
      }
    } else {
      // matched `default:`
      inDefault = true;
    }
  }
  expect(defaultValue, isNonNegative,
      reason: 'getPoints default return not parsed');
  return (cases: cases, defaultValue: defaultValue);
}

void main() {
  late String validatorsDart;
  late String profanityTs;
  late String monarchInfoDart;
  late String getPointsTs;
  late String importJs;
  late String reportRepoDart;
  late String reportsTs;
  late String homeWidgetDart;
  late String widgetProviderKt;

  setUpAll(() {
    validatorsDart = File('lib/validators.dart').readAsStringSync();
    profanityTs = File('functions/src/_profanityFilter.ts').readAsStringSync();
    monarchInfoDart = File('lib/monarch_info.dart').readAsStringSync();
    getPointsTs = File('functions/src/_getPoints.ts').readAsStringSync();
    importJs = File('functions/import_postboxes.js').readAsStringSync();
    reportRepoDart =
        File('lib/reports/report_repository.dart').readAsStringSync();
    reportsTs = File('functions/src/reports.ts').readAsStringSync();
    homeWidgetDart =
        File('lib/services/home_widget_service.dart').readAsStringSync();
    widgetProviderKt = File(
            'android/app/src/main/kotlin/com/code418/postbox_game/PostboxWidgetProvider.kt')
        .readAsStringSync();
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

  group('monarch point VALUES stay in sync across client/server', () {
    // The key-set test above pins WHICH ciphers exist; this pins what each is
    // WORTH. MonarchInfo.points (lib/monarch_info.dart) is the player-facing
    // mapping the UI shows ("VR = 7 pts"); getPoints (functions/src/_getPoints.ts)
    // is what startScoring actually awards. They're hand-duplicated and kept
    // aligned only by a "must stay in sync with _getPoints.ts" comment — a
    // one-sided rebalance (e.g. VR 7->8 on the server) would silently make the
    // client advertise a different score than the server grants.
    test('MonarchInfo.points[cipher] == getPoints(cipher) for every cipher',
        () {
      final dartPoints = _parseDartIntMap(monarchInfoDart, 'Map<String, int> points');
      final ts = _parseTsGetPoints(getPointsTs);
      final clientSet =
          _extractArrayLiterals(monarchInfoDart, 'List<String> all');

      // Sanity: parsing actually found the mappings.
      expect(dartPoints.length, greaterThan(5),
          reason: 'parsed too few Dart point values — extraction likely broke');
      expect(ts.cases.length, greaterThan(3),
          reason: 'parsed too few TS case values — extraction likely broke');

      // Every recognised cipher must map to the same value on both sides. The
      // TS side uses an explicit case where present, else its `default:`.
      for (final cipher in clientSet) {
        final dartVal = dartPoints[cipher];
        expect(dartVal, isNotNull,
            reason: 'MonarchInfo.points is missing a value for $cipher');
        final tsVal = ts.cases[cipher] ?? ts.defaultValue;
        expect(dartVal, equals(tsVal),
            reason: 'points drift for $cipher: '
                'Dart MonarchInfo.points=$dartVal vs TS getPoints=$tsVal');
      }

      // The unknown-cipher fallback must also agree (Dart `points[c] ?? 2`).
      expect(ts.defaultValue, equals(2),
          reason: 'TS getPoints default drifted from the documented 2');
    });
  });

  group('problem-report caps stay in sync across client/server', () {
    // The Dart side gates the picker/text-field; the TS side is the
    // authoritative validator at submitReport. A drift produces the worst
    // possible UX: the user picks photos / types a note that the client
    // happily accepts, then the report fails server-side after the upload
    // already burned their time and storage quota.

    test('maxPhotos (Dart) == MAX_PHOTOS (TS)', () {
      expect(
        _extractIntConst(reportRepoDart, 'maxPhotos'),
        equals(_extractIntConst(reportsTs, 'MAX_PHOTOS')),
      );
    });

    test('maxNoteChars (Dart) == NOTE_MAX (TS)', () {
      expect(
        _extractIntConst(reportRepoDart, 'maxNoteChars'),
        equals(_extractIntConst(reportsTs, 'NOTE_MAX')),
      );
    });

    test('maxReferenceChars (Dart) == REFERENCE_MAX (TS)', () {
      expect(
        _extractIntConst(reportRepoDart, 'maxReferenceChars'),
        equals(_extractIntConst(reportsTs, 'REFERENCE_MAX')),
      );
    });
  });

  group('storage photo-size cap stays in sync', () {
    // storage.rules accepts request.resource.size < N bytes for uploads under
    // report_photos/{uid}/. The Dart picker drops files where bytes.length >=
    // maxPhotoBytes, using the same N. A drift means the user picks a photo
    // the picker accepts but the upload then fails on a storage-rule reject.
    test('maxPhotoBytes (Dart) == storage.rules size cap', () {
      final dartM = RegExp(r'maxPhotoBytes\s*=\s*(\d+)\s*\*\s*1024\s*\*\s*1024')
          .firstMatch(reportRepoDart);
      expect(dartM, isNotNull, reason: 'maxPhotoBytes pattern not found');
      final dartMb = int.parse(dartM!.group(1)!);

      final storageRules = File('storage.rules').readAsStringSync();
      final rulesM = RegExp(r'size\s*<\s*(\d+)\s*\*\s*1024\s*\*\s*1024')
          .firstMatch(storageRules);
      expect(rulesM, isNotNull,
          reason: 'storage.rules size cap not found');
      final rulesMb = int.parse(rulesM!.group(1)!);

      expect(dartMb, equals(rulesMb),
          reason:
              'maxPhotoBytes=${dartMb}MB drifted from storage.rules=${rulesMb}MB');
    });
  });

  group('home-widget SharedPreferences keys stay in sync (Dart↔Kotlin)', () {
    // HomeWidgetService (Dart) WRITES the widget's data under these string
    // keys; PostboxWidgetProvider.kt READS them back to render the home-screen
    // widget. The `home_widget` package bridges the two purely by string key,
    // so a drift makes the native widget silently fall back to its defaults
    // (0 points, signed-out) even when the user has data — and the widget has
    // no automated UI test to catch it. Pin the key VALUES equal here.
    test('HomeWidgetService.key* == PostboxWidgetProvider KEY_* values', () {
      // Dart: `static const String keyFoo = 'value';`
      final dartKeys = RegExp(r'''static const String key\w+\s*=\s*['"]([^'"]+)['"]''')
          .allMatches(homeWidgetDart)
          .map((m) => m.group(1)!)
          .toSet();
      // Kotlin: `const val KEY_FOO = "value"`
      final ktKeys = RegExp(r'''const val KEY_\w+\s*=\s*"([^"]+)"''')
          .allMatches(widgetProviderKt)
          .map((m) => m.group(1)!)
          .toSet();

      // Sanity: extraction found the expected six keys on each side (guards
      // against a future rename that makes this test vacuous).
      expect(dartKeys.length, equals(6),
          reason: 'expected 6 Dart widget keys, parsed $dartKeys');
      expect(ktKeys.length, equals(6),
          reason: 'expected 6 Kotlin widget keys, parsed $ktKeys');

      expect(ktKeys, equals(dartKeys),
          reason: 'widget key drift between '
              'lib/services/home_widget_service.dart and '
              'PostboxWidgetProvider.kt — '
              'only-in-Dart=${dartKeys.difference(ktKeys)} '
              'only-in-Kotlin=${ktKeys.difference(dartKeys)}');
    });
  });

  group('claim radius stays in sync', () {
    // The Dart side controls the nearby-scan + claim-distance UI; the TS side
    // controls the server-authoritative geohash lookup. A drift means the
    // user can stand inside the client's claim ring but the server refuses
    // (or vice versa: server lets users claim outside the visualised ring).
    //
    // Mirrors the explicit "Must match" comment in startScoring.ts.
    test('AppPreferences.claimRadiusMeters == CLAIM_RADIUS_METERS', () {
      final appPrefsDart = File('lib/app_preferences.dart').readAsStringSync();
      final startScoringTs =
          File('functions/src/startScoring.ts').readAsStringSync();
      // Dart side is a `double` literal — match either form (30 or 30.0).
      final dartM = RegExp(r'claimRadiusMeters\s*=\s*(\d+(?:\.\d+)?)')
          .firstMatch(appPrefsDart);
      expect(dartM, isNotNull, reason: 'claimRadiusMeters not found in Dart');
      final dart = double.parse(dartM!.group(1)!);
      final ts = _extractIntConst(startScoringTs, 'CLAIM_RADIUS_METERS');
      expect(dart, equals(ts.toDouble()));
    });
  });

  group('Remote Config game-balance defaults stay in sync', () {
    // v1.4: claim_radius_meters + points_by_monarch are Remote-Config-driven,
    // but the hard-coded constants remain the canonical fallback. The RC
    // *defaults* must therefore equal those constants (ship first with defaults
    // == current code), and the server safety bounds (_config.ts) must match
    // the client's (RemoteConfigService) so a value the client accepts isn't
    // rejected server-side (or vice versa).

    test('RC points_by_monarch default JSON == MonarchInfo.points', () {
      final decoded =
          (jsonDecode(RemoteConfigService.defaultPointsByMonarchJson)
                  as Map<String, dynamic>)
              .map((k, v) => MapEntry(k, v as int));
      expect(decoded, equals(MonarchInfo.points));
    });

    test('RC claim_radius_meters default == AppPreferences.claimRadiusMeters',
        () {
      expect(
        RemoteConfigService.defaults[RemoteConfigService.keyClaimRadiusMeters],
        equals(AppPreferences.claimRadiusMeters),
      );
    });

    test('server _config.ts fallback + safety bounds match the Dart client',
        () {
      final configTs = File('functions/src/_config.ts').readAsStringSync();
      expect(_extractIntConst(configTs, 'DEFAULT_CLAIM_RADIUS_METERS'),
          equals(AppPreferences.claimRadiusMeters.toInt()));
      expect(_extractIntConst(configTs, 'MIN_CLAIM_RADIUS_METERS'),
          equals(RemoteConfigService.minClaimRadiusMeters.toInt()));
      expect(_extractIntConst(configTs, 'MAX_CLAIM_RADIUS_METERS'),
          equals(RemoteConfigService.maxClaimRadiusMeters.toInt()));
      expect(_extractIntConst(configTs, 'MIN_MONARCH_POINTS'),
          equals(RemoteConfigService.minMonarchPoints));
      expect(_extractIntConst(configTs, 'MAX_MONARCH_POINTS'),
          equals(RemoteConfigService.maxMonarchPoints));
    });
  });

  group('Remote Config template file stays deployable and in sync', () {
    // remoteconfig.template.json is what `firebase deploy --only remoteconfig`
    // publishes as the CLIENT template. Two failure modes guarded here, both
    // of which actually bit during v1.4:
    //
    //   1. A parameter exists in RemoteConfigService.defaults but not in the
    //      template, so the key never reaches production and the client
    //      silently serves its in-app default forever. Nothing errors — which
    //      is exactly how claim_radius_meters / points_by_monarch reached the
    //      v1.4 ship gate absent from both templates.
    //   2. A description grows past the Remote Config API's 256-char limit and
    //      the deploy dies with 400 DESCRIPTION_EXCEEDS_MAXIMUM_SIZE — at
    //      deploy time, against production, instead of in CI.
    //
    // IMPORTANT: only the game-balance pair is asserted equal to the code
    // defaults (the v1.4 ship gate requires publishing them with values equal
    // to code). The kill switches deliberately DIVERGE: the Dart default is
    // the safe in-app fallback (false = feature visible), while the template
    // mirrors live production state (kill_switch_route_mode is currently true,
    // hiding Route Mode from everyone outside the Admin audience). Do not
    // "fix" a future failure here by equating those — that would silently
    // re-enable Route Mode for all users on the next deploy.

    /// Remote Config API cap on any `description` field.
    const maxDescriptionChars = 256;

    late Map<String, dynamic> params;
    late Map<String, dynamic> template;

    setUpAll(() {
      template =
          jsonDecode(File('remoteconfig.template.json').readAsStringSync())
              as Map<String, dynamic>;
      params = template['parameters'] as Map<String, dynamic>;
    });

    /// The literal default value string for [key], or null if the parameter is
    /// absent or uses `useInAppDefault`.
    String? defaultValueOf(String key) {
      final param = params[key] as Map<String, dynamic>?;
      final defaultValue = param?['defaultValue'] as Map<String, dynamic>?;
      return defaultValue?['value'] as String?;
    }

    test('every RemoteConfigService.defaults key exists in the template', () {
      // Sanity: guard against a parse that silently found nothing.
      expect(params.length, greaterThan(3),
          reason: 'parsed too few template parameters — extraction likely '
              'broke or the template was truncated');

      final codeKeys = RemoteConfigService.defaults.keys.toSet();
      final missing = codeKeys.difference(params.keys.toSet());
      expect(missing, isEmpty,
          reason: 'keys declared in RemoteConfigService.defaults but absent '
              'from remoteconfig.template.json: $missing. The client will '
              'serve its in-app default for these forever — no error, just a '
              'parameter that never reaches production.');
    });

    test('template claim_radius_meters default == the code default', () {
      final raw = defaultValueOf(RemoteConfigService.keyClaimRadiusMeters);
      expect(raw, isNotNull,
          reason: 'claim_radius_meters has no literal defaultValue');
      expect(double.parse(raw!), equals(AppPreferences.claimRadiusMeters),
          reason: 'the published default must start equal to the code default');

      // functions/src/_config.ts reads this via getValue().asNumber(), so the
      // declared valueType has to be NUMBER for the server half to work.
      expect(
        (params[RemoteConfigService.keyClaimRadiusMeters]
            as Map<String, dynamic>)['valueType'],
        equals('NUMBER'),
      );
    });

    test('template points_by_monarch default == MonarchInfo.points', () {
      final raw = defaultValueOf(RemoteConfigService.keyPointsByMonarch);
      expect(raw, isNotNull,
          reason: 'points_by_monarch has no literal defaultValue');
      final decoded = (jsonDecode(raw!) as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, v as int));
      expect(decoded, equals(MonarchInfo.points),
          reason: 'the published points default drifted from MonarchInfo.points '
              '— publishing this template would re-score the game');

      // Read server-side via getValue().asString(), which returns the raw JSON.
      expect(
        (params[RemoteConfigService.keyPointsByMonarch]
            as Map<String, dynamic>)['valueType'],
        equals('JSON'),
      );
    });

    test('no description exceeds the Remote Config 256-char limit', () {
      final overLong = <String, int>{};
      for (final entry in params.entries) {
        final description =
            (entry.value as Map<String, dynamic>)['description'] as String?;
        if (description != null && description.length > maxDescriptionChars) {
          overLong[entry.key] = description.length;
        }
      }
      final versionDescription =
          (template['version'] as Map<String, dynamic>?)?['description']
              as String?;
      if (versionDescription != null &&
          versionDescription.length > maxDescriptionChars) {
        overLong['version.description'] = versionDescription.length;
      }

      expect(overLong, isEmpty,
          reason: 'descriptions longer than $maxDescriptionChars chars will '
              'fail the deploy with 400 DESCRIPTION_EXCEEDS_MAXIMUM_SIZE: '
              '$overLong');
    });
  });
}
