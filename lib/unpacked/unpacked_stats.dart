import 'package:postbox_game/monarch_info.dart';

/// One player's "Your Postboxes Unpacked" annual recap, as written by the
/// `buildUnpacked` Cloud Function to `unpacked/{year}/players/{uid}`.
///
/// Parsing is deliberately forgiving: a missing or malformed field becomes a
/// zero/null and the card that needs it is skipped, rather than the whole
/// recap failing on an older or newer snapshot shape.
class UnpackedStats {
  const UnpackedStats({
    required this.year,
    required this.totalClaims,
    required this.uniquePostboxes,
    required this.totalPoints,
    required this.daysActive,
    required this.longestStreakDays,
    required this.busiestMonth,
    required this.busiestMonthClaims,
    required this.favouriteWeekday,
    required this.busiestDayDate,
    required this.busiestDayPoints,
    required this.rarestMonarch,
    required this.rarestPoints,
    required this.rarestReference,
    required this.monarchCounts,
    required this.topCountyName,
    required this.topCountyBoxes,
    required this.countiesVisited,
    required this.percentileBoxes,
    required this.percentilePoints,
    required this.percentileStreak,
    this.firstClaimDate,
    this.throughDate,
  });

  final int year;
  final int totalClaims;
  final int uniquePostboxes;
  final int totalPoints;
  final int daysActive;
  final int longestStreakDays;

  /// 1–12, or 0 when unknown.
  final int busiestMonth;
  final int busiestMonthClaims;

  /// ISO weekday 1 (Monday) – 7 (Sunday), or 0 when unknown.
  final int favouriteWeekday;
  final String? busiestDayDate;
  final int busiestDayPoints;

  /// Cypher of the highest-scoring claim; [MonarchInfo.plainKey] for a plain
  /// box, null when the snapshot has no rarest find.
  final String? rarestMonarch;
  final int rarestPoints;
  final String? rarestReference;

  /// Claims per cypher, plain boxes keyed by [MonarchInfo.plainKey], sorted
  /// most-claimed first.
  final List<MapEntry<String, int>> monarchCounts;
  final String? topCountyName;
  final int topCountyBoxes;
  final int countiesVisited;

  /// Share of players (0–99) this player beat.
  final int percentileBoxes;
  final int percentilePoints;
  final int percentileStreak;
  final String? firstClaimDate;

  /// Last London day the snapshot counts (the build runs on 1 December, so
  /// this is usually 30 November or 1 December, not 31 December).
  final String? throughDate;

  /// Server's key for a plain/unknown cypher.
  static const String serverPlainKey = 'NONE';

  static int _int(Object? v) => v is num && v.isFinite ? v.toInt() : 0;
  static String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;
  static Map<String, dynamic> _map(Object? v) =>
      v is Map ? v.map((k, val) => MapEntry('$k', val)) : const {};

  factory UnpackedStats.fromMap(Map<String, dynamic> m, {required int year}) {
    final streak = _map(m['longestStreak']);
    final month = _map(m['busiestMonth']);
    final weekday = _map(m['favouriteWeekday']);
    final day = _map(m['busiestDay']);
    final rarest = _map(m['rarestFind']);
    final county = _map(m['topCounty']);
    final pct = _map(m['percentiles']);

    String? rarestMonarch;
    if (rarest.isNotEmpty) {
      rarestMonarch = _str(rarest['monarch']) ?? MonarchInfo.plainKey;
    }

    final counts = <MapEntry<String, int>>[];
    _map(m['monarchCounts']).forEach((k, v) {
      final n = _int(v);
      if (n <= 0) return;
      counts.add(MapEntry(k == serverPlainKey ? MonarchInfo.plainKey : k, n));
    });
    counts.sort((a, b) {
      final c = b.value.compareTo(a.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    });

    final busiestMonth = _int(month['month']);
    final fav = _int(weekday['weekday']);
    return UnpackedStats(
      year: _int(m['year']) == 0 ? year : _int(m['year']),
      totalClaims: _int(m['totalClaims']),
      uniquePostboxes: _int(m['uniquePostboxes']),
      totalPoints: _int(m['totalPoints']),
      daysActive: _int(m['daysActive']),
      longestStreakDays: _int(streak['days']),
      busiestMonth: busiestMonth >= 1 && busiestMonth <= 12 ? busiestMonth : 0,
      busiestMonthClaims: _int(month['claims']),
      favouriteWeekday: fav >= 1 && fav <= 7 ? fav : 0,
      busiestDayDate: _str(day['date']),
      busiestDayPoints: _int(day['points']),
      rarestMonarch: rarestMonarch,
      rarestPoints: _int(rarest['points']),
      rarestReference: _str(rarest['reference']),
      monarchCounts: List.unmodifiable(counts),
      topCountyName: _str(county['name']),
      topCountyBoxes: _int(county['uniquePostboxes']),
      countiesVisited: _int(m['countiesVisited']),
      percentileBoxes: _int(pct['uniquePostboxes']).clamp(0, 99),
      percentilePoints: _int(pct['totalPoints']).clamp(0, 99),
      percentileStreak: _int(pct['longestStreak']).clamp(0, 99),
      firstClaimDate: _str(m['firstClaimDate']),
      throughDate: _str(m['throughDate']),
    );
  }

  bool get isEmpty => totalClaims == 0;
}

/// The community-wide `unpacked/{year}` summary doc.
class UnpackedSummary {
  const UnpackedSummary({
    required this.year,
    required this.players,
    required this.totalClaims,
    required this.uniquePostboxes,
    required this.topMonarch,
    required this.availableFrom,
    required this.availableUntil,
  });

  final int year;
  final int players;
  final int totalClaims;
  final int uniquePostboxes;
  final String? topMonarch;

  /// Inclusive London dates ("YYYY-MM-DD") bounding when the recap is shown.
  final String availableFrom;
  final String availableUntil;

  factory UnpackedSummary.fromMap(Map<String, dynamic> m, {required int year}) {
    return UnpackedSummary(
      year: year,
      players: UnpackedStats._int(m['players']),
      totalClaims: UnpackedStats._int(m['totalClaims']),
      uniquePostboxes: UnpackedStats._int(m['uniquePostboxes']),
      topMonarch: UnpackedStats._str(m['topMonarch']),
      // Fall back to the documented window so a summary missing the fields
      // still behaves (mirrors unpackedWindow in functions/src/_unpacked.ts).
      availableFrom: UnpackedStats._str(m['availableFrom']) ?? '$year-12-01',
      availableUntil:
          UnpackedStats._str(m['availableUntil']) ?? '${year + 1}-01-15',
    );
  }

  bool isOpenOn(String todayLondon) =>
      todayLondon.compareTo(availableFrom) >= 0 &&
      todayLondon.compareTo(availableUntil) <= 0;
}

/// Which recap year is current on [todayLondon]: this year in December, last
/// year during January. Mirrors `unpackedYearFor` in functions/src/_unpacked.ts.
int unpackedYearFor(String todayLondon) {
  final year = int.parse(todayLondon.substring(0, 4));
  return todayLondon.substring(5, 7) == '12' ? year : year - 1;
}

const List<String> monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', //
  'August', 'September', 'October', 'November', 'December',
];

const List<String> weekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
