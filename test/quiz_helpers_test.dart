import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/widgets/quiz_helpers.dart';

/// Pins the shared quiz helpers extracted from ClaimQuizSheet + WearClaimPage.
/// Before extraction both call sites carried near-copies that drifted in
/// `Map` typing and option count; tests here guarantee neither path can
/// silently regress the "valid cypher" filter or the option-pool shape.

void main() {
  _plainCountTests();
  group('collectValidQuizCiphers', () {
    test('empty values → empty set', () {
      expect(collectValidQuizCiphers(const []), isEmpty);
    });

    test('excludes claimedToday boxes', () {
      final ciphers = collectValidQuizCiphers([
        {'monarch': 'EIIR', 'claimedToday': true},
        {'monarch': 'VR', 'claimedToday': false},
      ]);
      expect(ciphers, equals({'VR'}));
    });

    test('skips unknown monarchs (not in MonarchInfo.all)', () {
      final ciphers = collectValidQuizCiphers([
        {'monarch': 'GHOST_MONARCH', 'claimedToday': false},
        {'monarch': 'EIIR', 'claimedToday': false},
      ]);
      expect(ciphers, equals({'EIIR'}));
    });

    test('skips null and empty monarchs (plain boxes)', () {
      final ciphers = collectValidQuizCiphers([
        {'monarch': null, 'claimedToday': false},
        {'monarch': '', 'claimedToday': false},
        {'claimedToday': false}, // monarch absent entirely
        {'monarch': 'GR', 'claimedToday': false},
      ]);
      expect(ciphers, equals({'GR'}));
    });

    test('deduplicates when multiple boxes share a cypher', () {
      final ciphers = collectValidQuizCiphers([
        {'monarch': 'EIIR', 'claimedToday': false},
        {'monarch': 'EIIR', 'claimedToday': false},
        {'monarch': 'EIIR', 'claimedToday': false},
      ]);
      expect(ciphers, equals({'EIIR'}));
    });

    test('accepts both Map<String, dynamic> and Map<dynamic, dynamic>', () {
      // The phone path stores inner maps as Map<String, dynamic>; the wear
      // path stores them as Map<dynamic, dynamic>. The shared helper has to
      // accept both — pin the contract here.
      final ciphers = collectValidQuizCiphers([
        <String, dynamic>{'monarch': 'EIIR', 'claimedToday': false},
        <dynamic, dynamic>{'monarch': 'VR', 'claimedToday': false},
      ]);
      expect(ciphers, equals({'EIIR', 'VR'}));
    });

    test('ignores non-Map entries (defensive — never expected in prod)', () {
      final ciphers = collectValidQuizCiphers([
        'not a map',
        42,
        {'monarch': 'EIIR', 'claimedToday': false},
      ]);
      expect(ciphers, equals({'EIIR'}));
    });
  });

  group('buildQuizOptions', () {
    test('returns exactly maxOptions entries', () {
      expect(buildQuizOptions({'EIIR'}, maxOptions: 4), hasLength(4));
      expect(buildQuizOptions({'EIIR', 'VR'}, maxOptions: 2), hasLength(2));
    });

    test('always includes every valid cipher up to maxOptions', () {
      final opts = buildQuizOptions({'EIIR', 'VR', 'GR'}, maxOptions: 4);
      // All three valid cyphers must appear so the user can pick whichever
      // they're looking at.
      expect(opts, containsAll(<String>['EIIR', 'VR', 'GR']));
    });

    test('caps valid cyphers at maxOptions when there are too many', () {
      // 5 valid cyphers but only 2 option slots — the helper truncates the
      // VISIBLE set; the caller's `validQuizCiphers` check still accepts the
      // rest as correct answers, just without a row to tap.
      final valid = {'EIIR', 'VR', 'GR', 'GVR', 'CIIIR'};
      final opts = buildQuizOptions(valid, maxOptions: 2);
      expect(opts, hasLength(2));
      // Every rendered option must be drawn from validCiphers; no distractors
      // when validCiphers already overflows maxOptions.
      for (final o in opts) {
        expect(valid.contains(o), isTrue,
            reason: '$o is not in the valid set — distractor leaked past cap');
      }
    });

    test('fills with distractors from MonarchInfo.all when room remains', () {
      final opts = buildQuizOptions({'EIIR'}, maxOptions: 4);
      // Exactly one valid + three distractors, and distractors must NOT be
      // EIIR (already picked).
      expect(opts.where((o) => o == 'EIIR'), hasLength(1));
      for (final o in opts.where((o) => o != 'EIIR')) {
        expect(MonarchInfo.all.contains(o), isTrue,
            reason: 'distractor $o is not in MonarchInfo.all');
      }
    });

    test('handles empty validCiphers by filling entirely with distractors',
        () {
      final opts = buildQuizOptions(const {}, maxOptions: 3);
      expect(opts, hasLength(3));
      for (final o in opts) {
        expect(MonarchInfo.all.contains(o), isTrue);
      }
    });

    test('never produces duplicate options', () {
      // Two identical quiz buttons would let the user "identify" a cypher that
      // appears twice, and looks broken. Guaranteed today by the Set source +
      // disjoint filler pool; pin it so a future filler change can't regress.
      // Cover the distractor-padded, exactly-full, and overflow cases.
      for (final valid in <Set<String>>[
        const {}, // all distractors
        const {'EIIR'}, // 1 valid + distractors
        const {'EIIR', 'VR', 'GR', 'GVR'}, // exactly fills maxOptions=4
        const {'EIIR', 'VR', 'GR', 'GVR', 'CIIIR', 'EVIIR'}, // overflow
      ]) {
        final opts = buildQuizOptions(valid, maxOptions: 4);
        expect(opts.toSet(), hasLength(opts.length),
            reason: 'duplicate option produced for validCiphers=$valid');
      }
    });
  });
}

// ── Plain / no-cypher accounting (MonarchInfo.plainCount) ────────────────────
//
// Found on a live emulator scan: Nearby said "18 postboxes nearby" above a
// type breakdown listing 15 + 1 = 16. `import_postboxes.js` deliberately
// stores an unknown or multi-value royal_cypher (e.g. "VR;GR") with NO monarch
// field, so the server counts those boxes in `total` but under no per-cypher
// key — and a breakdown that only walks MonarchInfo.all drops them silently.
void _plainCountTests() {
  group('MonarchInfo.plainCount', () {
    test('is the remainder the recognised cyphers do not account for', () {
      // The exact shape observed on the emulator: 18 total, EIIR 15, EVIIR 1.
      expect(MonarchInfo.plainCount(18, const [15, 1]), 2);
    });

    test('is zero when every box has a recognised cypher', () {
      expect(MonarchInfo.plainCount(16, const [15, 1]), 0);
    });

    test('never goes negative on an inconsistent response', () {
      // A partial/garbled payload must not render a negative row.
      expect(MonarchInfo.plainCount(3, const [5, 2]), 0);
      expect(MonarchInfo.plainCount(0, const []), 0);
    });

    test('handles an empty cypher set (all boxes plain)', () {
      expect(MonarchInfo.plainCount(4, const []), 4);
    });

    test('PLAIN is not a quiz answer or a server-recognised cypher', () {
      // MonarchInfo.all is the quiz answer pool AND is pinned against the
      // server's KNOWN_MONARCHS / the importer's VALID_CIPHERS, so the display
      // sentinel must never leak into it.
      expect(MonarchInfo.all, isNot(contains(MonarchInfo.plainKey)));
      expect(MonarchInfo.points.containsKey(MonarchInfo.plainKey), isFalse);
      // It does need a label, or the row renders as the raw sentinel.
      expect(MonarchInfo.labels[MonarchInfo.plainKey], isNotNull);
    });
  });
}
