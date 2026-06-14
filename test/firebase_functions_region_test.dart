// Region-pinning guard for the Flutter client (ROADMAP v1.3,
// us-central1 -> europe-west2). Every Cloud Functions callable must go through
// the single europe-west2-pinned helper in lib/firebase_functions_eu.dart
// (`appFunctions`), never the US-default `FirebaseFunctions.instance`. A call
// site that reaches for `FirebaseFunctions.instance` would hit us-central1 and
// re-introduce the cross-Atlantic latency the migration removes — and would
// keep us-central1 invocations non-zero, blocking decommission of the old
// functions.
//
// Plain VM test (dart:io) — `flutter test` runs with the package root as the
// working directory, so the relative paths resolve.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const helperPath = 'lib/firebase_functions_eu.dart';

  test('appFunctions helper is pinned to europe-west2', () {
    final helper = File(helperPath);
    expect(helper.existsSync(), isTrue,
        reason: 'missing $helperPath — the single region-pinned callable seam');
    final src = helper.readAsStringSync();
    expect(src.contains("instanceFor(region: 'europe-west2')"), isTrue,
        reason: '$helperPath must expose a europe-west2 FirebaseFunctions');
    expect(src.contains('appFunctions'), isTrue,
        reason: '$helperPath must expose the `appFunctions` getter');
  });

  test('no callable bypasses the helper via FirebaseFunctions.instance', () {
    // Matches `FirebaseFunctions.instance` (incl. multi-line `.httpsCallable`
    // call sites and doc-comment references) but not `instanceFor` or
    // `FirebaseFunctionsException`.
    final offenderRe = RegExp(r'FirebaseFunctions\.instance(?!For)');
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // The helper itself is the one place allowed to name the default
      // instance (its doc comment explains why callers must avoid it).
      if (entity.path.endsWith('firebase_functions_eu.dart')) continue;
      final content = entity.readAsStringSync();
      for (final m in offenderRe.allMatches(content)) {
        final line = '\n'.allMatches(content.substring(0, m.start)).length + 1;
        offenders.add('${entity.path}:$line');
      }
    }
    expect(offenders, isEmpty,
        reason: 'these references use the US-default FirebaseFunctions.instance '
            'instead of the europe-west2 `appFunctions` helper:\n'
            '${offenders.join('\n')}');
  });
}
