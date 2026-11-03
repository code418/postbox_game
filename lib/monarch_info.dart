import 'package:flutter/material.dart';
import 'package:postbox_game/theme.dart';

/// Shared monarch cipher metadata used across Nearby, Claim, and other screens.
abstract final class MonarchInfo {
  MonarchInfo._();

  /// Display-only key for postboxes carrying no recognised cypher.
  ///
  /// `import_postboxes.js` deliberately stores an unknown or multi-value
  /// `royal_cypher` tag (e.g. "VR;GR") with NO monarch field, and the box
  /// scores the default 2 points. The server counts it in `counts.total` but
  /// under no per-cypher key, so any breakdown that only walks [all] drops it:
  /// Nearby showed "18 postboxes nearby" above a list adding up to 16, with no
  /// hint the other two existed or were claimable.
  ///
  /// Deliberately NOT a member of [all]. That list is the quiz answer pool and
  /// is pinned against the server's `KNOWN_MONARCHS` and the importer's
  /// `VALID_CIPHERS`; this key never travels to the server and must never
  /// become a quiz answer. It exists purely so the numbers on screen add up.
  static const String plainKey = 'PLAIN';

  /// Human-readable labels for each royal cipher.
  static const Map<String, String> labels = {
    // Matches the CypherPicker wording in reports/report_form_widgets.dart.
    plainKey: 'Plain / no cypher',
    'EIIR': 'Elizabeth II (1952–2022)',
    'CIIIR': 'Charles III (2022–)',
    'GVIR': 'George VI (1936–1952)',
    'GVR': 'George V (1910–1936)',
    'EVIIIR': 'Edward VIII (1936)',
    'EVIIR': 'Edward VII (1901–1910)',
    'VR': 'Victoria (1837–1901)',
    // OSM's "GR" is a George box recorded without its numeral.
    'GR': 'George (V or VI)',
    'SCOTTISH_CROWN': 'Scottish Crown (Scotland only)',
  };

  /// The name part of [labels]: "Elizabeth II (1952–2022)" → "Elizabeth II".
  /// Unknown codes come back unchanged.
  static String nameOf(String code) =>
      (labels[code] ?? code).replaceFirst(_parenthetical, '');

  /// The bracketed part of [labels] ("1952–2022", "Scotland only"), or null
  /// when the label has none.
  static String? detailOf(String code) =>
      _parenthetical.firstMatch(labels[code] ?? '')?.group(1);

  static final RegExp _parenthetical = RegExp(r'\s*\(([^)]*)\)$');

  /// What to look for on the box, for the Cypher guide
  /// (lib/cypher_guide_screen.dart). One entry per member of [all].
  static const Map<String, String> lookFor = {
    'VR': 'V R in flowing letters. The oldest boxes still in use.',
    'EVIIR': 'E VII R under a crown. Count the I\'s: two after the V.',
    'GVR': 'G R under a crown. George V\'s boxes rarely show his numeral.',
    'GR': 'G R under a crown, recorded without a numeral.',
    'EVIIIR': 'E VIII R under a crown. Three I\'s, and a reign of under a '
        'year, so they\'re rare.',
    'GVIR': 'G VI R under a crown.',
    'EIIR': 'E II R under St Edward\'s Crown, whose arches dip in the '
        'middle. The most common cypher.',
    'CIIIR': 'C III R under a crown. The newest boxes, from 2022.',
    'SCOTTISH_CROWN': 'A crown and no letters. Scottish boxes carry it '
        'instead of a royal cypher.',
  };

  /// [all] oldest first: the Cypher guide's "By reign" order.
  static const List<String> reignOrder = [
    'VR', 'EVIIR', 'GVR', 'GR', 'EVIIIR', 'GVIR', 'EIIR', 'CIIIR',
    'SCOTTISH_CROWN',
  ];

  /// Display colours for each cipher.
  static const Map<String, Color> colors = {
    plainKey: Colors.blueGrey,
    'EIIR': postalRed,
    'CIIIR': postalRed,
    'GVIR': Colors.indigo,
    'GVR': Colors.teal,
    'EVIIIR': postalGold,
    'EVIIR': Colors.deepPurple,
    'VR': Colors.amber,
    'GR': Colors.blueGrey,
    'SCOTTISH_CROWN': Color(0xFF005EB8), // Saltire blue
  };

  /// Ciphers that are considered rare (shown with a star badge).
  static const Set<String> rareCiphers = {'EVIIIR', 'CIIIR'};

  /// Ciphers that are considered historic (shown with a "Historic" badge).
  static const Set<String> historicCiphers = {'VR', 'EVIIR'};

  /// All known ciphers in display order — used for quiz answer pools etc.
  static const List<String> all = [
    'EIIR', 'CIIIR', 'GR', 'GVR', 'GVIR', 'VR', 'EVIIR', 'EVIIIR',
    'SCOTTISH_CROWN',
  ];

  /// Point values per cipher — must stay in sync with _getPoints.ts.
  static const Map<String, int> points = {
    'EIIR': 2,
    'CIIIR': 9,
    'GR': 4,
    'GVR': 4,
    'GVIR': 4,
    'VR': 7,
    'EVIIR': 9,
    'EVIIIR': 12,
    'SCOTTISH_CROWN': 4,
  };

  /// Returns the point value for [cipher], or 2 if unknown (matches server default).
  static int getPoints(String cipher) => points[cipher] ?? 2;

  /// How many of [total] scanned postboxes fall outside every recognised
  /// cypher — the [plainKey] row's count.
  ///
  /// The server reports one `counts` key per cypher plus an overall `total`,
  /// and a box with no monarch field contributes only to the latter. So the
  /// plain count is whatever the recognised cyphers don't account for.
  /// Clamped at zero so a partial or inconsistent response can never render a
  /// negative row.
  static int plainCount(int total, Iterable<int> knownCipherCounts) {
    final known = knownCipherCounts.fold<int>(0, (a, b) => a + b);
    return total > known ? total - known : 0;
  }
}
