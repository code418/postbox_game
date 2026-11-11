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
    this.busiestDays = const [],
    this.otherCounties = const [],
    this.friendStreaks = const [],
    this.friendAwards = const [],
    this.favouritePostboxes = const [],
    this.monthCounts = const [],
    this.weekdayPoints = const [],
    this.countyBoxes = const {},
    this.rarestCounty,
    this.topFriendsDays = 0,
    this.topEveryoneDays = 0,
    this.complete = false,
    this.longestStreakStart,
    this.longestStreakEnd,
    this.rarestDate,
  });

  final int year;
  final int totalClaims;
  final int uniquePostboxes;
  final int totalPoints;
  final int daysActive;
  final int longestStreakDays;

  /// First and last London days of [longestStreakDays], when known.
  final String? longestStreakStart;
  final String? longestStreakEnd;

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

  /// London day the [rarestMonarch] box was first found, when known.
  final String? rarestDate;

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

  /// Last London day the snapshot counts: the cut-off (the last
  /// second-class posting day, 18 December in 2026) for the final build, or
  /// the build day for an early admin build.
  final String? throughDate;

  /// The year's top days by claims (at most three). Falls back to
  /// [busiestDayDate] alone for a snapshot built before the list existed.
  final List<UnpackedDay> busiestDays;

  /// The player's next-best counties after [topCountyName], each shared with
  /// at least one other player.
  final List<UnpackedCounty> otherCounties;

  /// Friends' best streaks of the year, longest first. Uids only: the
  /// repository resolves names when it loads the recap.
  final List<UnpackedFriendStreak> friendStreaks;

  /// The award podium's friends: top friends by days out hunting, then
  /// boxes found (at most three). Uids only, like [friendStreaks].
  final List<UnpackedFriendAward> friendAwards;

  /// Every friend uid the recap mentions, for the name lookup.
  Set<String> get friendUids => {
        for (final f in friendStreaks) f.uid,
        for (final f in friendAwards) f.uid
      };

  /// The boxes claimed on the most days (each at least two), most first.
  final List<UnpackedFavourite> favouritePostboxes;

  /// Claims per month, January first: 12 entries, or empty for a snapshot
  /// built before the field existed.
  final List<int> monthCounts;

  /// Points per weekday, Monday first: 7 entries, or empty.
  final List<int> weekdayPoints;

  /// Distinct boxes per county the player claimed in.
  final Map<String, int> countyBoxes;

  /// County of the [rarestMonarch] box, when known.
  final String? rarestCounty;

  /// Days the player was top (or joint top) scorer among their friends, and
  /// among every player. A day only counts when someone else scored too.
  final int topFriendsDays;
  final int topEveryoneDays;

  /// True when the snapshot counts all the way to the cut-off (the last
  /// second-class posting day); false for an early admin build.
  final bool complete;

  /// Server's key for a plain/unknown cypher.
  static const String serverPlainKey = 'NONE';

  static int _int(Object? v) => v is num && v.isFinite ? v.toInt() : 0;
  static String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;
  static Map<String, dynamic> _map(Object? v) =>
      v is Map ? v.map((k, val) => MapEntry('$k', val)) : const {};
  static List<Map<String, dynamic>> _maps(Object? v) => v is List
      ? [
          for (final e in v)
            if (e is Map) _map(e)
        ]
      : const [];

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

    final days = [
      for (final d in _maps(m['busiestDays']))
        if (_str(d['date']) != null)
          UnpackedDay(
              date: _str(d['date'])!,
              claims: _int(d['claims']),
              points: _int(d['points'])),
    ];
    if (days.isEmpty && _str(day['date']) != null) {
      days.add(UnpackedDay(
          date: _str(day['date'])!,
          claims: _int(day['claims']),
          points: _int(day['points'])));
    }

    List<int> ints(Object? v, int length) {
      if (v is! List || v.length != length) return const [];
      return List.unmodifiable([for (final e in v) _int(e)]);
    }

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
      busiestDays: List.unmodifiable(days),
      monthCounts: ints(m['monthCounts'], 12),
      weekdayPoints: ints(m['weekdayPoints'], 7),
      countyBoxes: Map.unmodifiable({
        for (final e in _map(m['countyBoxes']).entries)
          if (e.key.isNotEmpty && _int(e.value) > 0) e.key: _int(e.value),
      }),
      rarestCounty: _str(rarest['county']),
      topFriendsDays: _int(_map(m['topScorerDays'])['friends']),
      topEveryoneDays: _int(_map(m['topScorerDays'])['everyone']),
      complete: m['complete'] == true,
      longestStreakStart: _str(streak['start']),
      longestStreakEnd: _str(streak['end']),
      rarestDate: _str(rarest['dailyDate']),
      otherCounties: List.unmodifiable([
        for (final c in _maps(m['otherCounties']))
          if (_str(c['name']) != null)
            UnpackedCounty(
                name: _str(c['name'])!,
                uniquePostboxes: _int(c['uniquePostboxes']),
                otherPlayers: _int(c['otherPlayers'])),
      ]),
      friendStreaks: List.unmodifiable([
        for (final f in _maps(m['friendStreaks']))
          if (_str(f['uid']) != null && _int(f['days']) > 0)
            UnpackedFriendStreak(uid: _str(f['uid'])!, days: _int(f['days'])),
      ]),
      friendAwards: List.unmodifiable([
        for (final f in _maps(m['friendAwards']))
          if (_str(f['uid']) != null && _int(f['daysActive']) > 0)
            UnpackedFriendAward(
                uid: _str(f['uid'])!,
                daysActive: _int(f['daysActive']),
                uniquePostboxes: _int(f['uniquePostboxes'])),
      ]),
      favouritePostboxes: List.unmodifiable([
        for (final b in _maps(m['favouritePostboxes']))
          if (_int(b['claims']) >= 2)
            UnpackedFavourite(
              claims: _int(b['claims']),
              monarch: _str(b['monarch']) ?? MonarchInfo.plainKey,
              reference: _str(b['reference']),
              county: _str(b['county']),
              fans: _int(b['fans']) > 0 ? _int(b['fans']) : 1,
              topFan: b['topFan'] != false,
            ),
      ]),
    );
  }

  bool get isEmpty => totalClaims == 0;
}

/// One day in [UnpackedStats.busiestDays].
class UnpackedDay {
  const UnpackedDay(
      {required this.date, required this.claims, required this.points});
  final String date;
  final int claims;
  final int points;
}

/// One county in [UnpackedStats.otherCounties].
class UnpackedCounty {
  const UnpackedCounty(
      {required this.name,
      required this.uniquePostboxes,
      required this.otherPlayers});
  final String name;
  final int uniquePostboxes;
  final int otherPlayers;
}

/// One friend in [UnpackedStats.friendStreaks].
class UnpackedFriendStreak {
  const UnpackedFriendStreak({required this.uid, required this.days});
  final String uid;
  final int days;
}

/// One friend in [UnpackedStats.friendAwards].
class UnpackedFriendAward {
  const UnpackedFriendAward(
      {required this.uid,
      required this.daysActive,
      required this.uniquePostboxes});
  final String uid;
  final int daysActive;
  final int uniquePostboxes;
}

/// One box in [UnpackedStats.favouritePostboxes]. [monarch] is
/// [MonarchInfo.plainKey] for a plain box.
class UnpackedFavourite {
  const UnpackedFavourite({
    required this.claims,
    required this.monarch,
    this.reference,
    this.county,
    this.fans = 1,
    this.topFan = true,
  });
  final int claims;
  final String monarch;
  final String? reference;
  final String? county;

  /// Players who claimed this box this year, the player included.
  final int fans;

  /// Nobody claimed it on more days than the player.
  final bool topFan;
}

/// The anonymous community figures on the "Together" card
/// (`unpacked/{year}.highlights`).
class UnpackedHighlights {
  const UnpackedHighlights({
    required this.countiesCovered,
    required this.rarestCypher,
    required this.rarestCypherBoxes,
    required this.longestStreak,
    required this.busiestDayDate,
    required this.busiestDayClaims,
    required this.daysWithClaims,
    required this.daysSoFar,
    this.sharedCounties = const [],
  });

  final int countiesCovered;

  /// The rarest cypher anyone found, or null.
  final String? rarestCypher;
  final int rarestCypherBoxes;

  /// The best streak any player managed (nobody is named).
  final int longestStreak;
  final String? busiestDayDate;
  final int busiestDayClaims;
  final int daysWithClaims;
  final int daysSoFar;

  /// Counties where at least two players claimed (for the map).
  final List<String> sharedCounties;

  factory UnpackedHighlights.fromMap(Map<String, dynamic> m) {
    final rarest = UnpackedStats._map(m['rarestCypher']);
    final day = UnpackedStats._map(m['busiestDay']);
    return UnpackedHighlights(
      countiesCovered: UnpackedStats._int(m['countiesCovered']),
      rarestCypher: UnpackedStats._str(rarest['monarch']),
      rarestCypherBoxes: UnpackedStats._int(rarest['boxes']),
      longestStreak: UnpackedStats._int(m['longestStreak']),
      busiestDayDate: UnpackedStats._str(day['date']),
      busiestDayClaims: UnpackedStats._int(day['claims']),
      daysWithClaims: UnpackedStats._int(m['daysWithClaims']),
      daysSoFar: UnpackedStats._int(m['daysSoFar']),
      sharedCounties: List.unmodifiable([
        if (m['sharedCounties'] is List)
          for (final c in m['sharedCounties'] as List)
            if (c is String && c.isNotEmpty) c,
      ]),
    );
  }
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
    this.highlights,
    String? lastFirstClass,
  }) : lastFirstClass = lastFirstClass ?? '$year-12-21';

  final int year;
  final int players;
  final int totalClaims;
  final int uniquePostboxes;
  final String? topMonarch;

  /// Inclusive London dates ("YYYY-MM-DD") bounding when the recap is shown.
  final String availableFrom;
  final String availableUntil;

  /// Null for a summary built before the highlights existed.
  final UnpackedHighlights? highlights;

  /// Royal Mail's last first-class posting day before Christmas, for the
  /// guide's Christmas-card nudge (`unpackedLastFirstClass` on the server).
  final String lastFirstClass;

  factory UnpackedSummary.fromMap(Map<String, dynamic> m, {required int year}) {
    return UnpackedSummary(
      year: year,
      players: UnpackedStats._int(m['players']),
      totalClaims: UnpackedStats._int(m['totalClaims']),
      uniquePostboxes: UnpackedStats._int(m['uniquePostboxes']),
      topMonarch: UnpackedStats._str(m['topMonarch']),
      // Fall back to the documented window so a summary missing the fields
      // still behaves (mirrors unpackedWindow in functions/src/_unpacked.ts).
      availableFrom: UnpackedStats._str(m['availableFrom']) ?? '$year-12-19',
      availableUntil:
          UnpackedStats._str(m['availableUntil']) ?? '${year + 1}-01-15',
      highlights: m['highlights'] is Map
          ? UnpackedHighlights.fromMap(UnpackedStats._map(m['highlights']))
          : null,
      lastFirstClass: UnpackedStats._str(m['lastFirstClass']),
    );
  }

  bool isOpenOn(String todayLondon) =>
      todayLondon.compareTo(availableFrom) >= 0 &&
      todayLondon.compareTo(availableUntil) <= 0;
}

/// A county name as the cards show it. Postbox docs carry ONS names, three
/// of which put the type last ("Bristol, City of", "Kingston upon Hull, City
/// of", "Herefordshire, County of"); the cards drop that tail. Maps still
/// match on the stored name.
String countyDisplayName(String name) =>
    name.replaceFirst(RegExp(r',\s*(City|County) of\s*$'), '');

/// A cypher's name without its reign dates: "Edward VIII", "George (generic)",
/// "Plain / no cypher". For the share image and the "still to find" list,
/// where the dates would crowd the text.
String cypherShortName(String key) => (MonarchInfo.labels[key] ?? key)
    .replaceFirst(RegExp(r'\s*\(\d[^)]*\)$'), '');

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
