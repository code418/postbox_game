import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/london_date.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/postman_james.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/unpacked/unpacked_repository.dart';
import 'package:postbox_game/unpacked/unpacked_share_card.dart';
import 'package:postbox_game/unpacked/unpacked_stats.dart';
import 'package:postbox_game/unpacked/uk_county_map.dart';
import 'package:postbox_game/widgets/share_card.dart'
    show kShareLinkUrl, renderShareCardPng;
import 'package:share_plus/share_plus.dart';

/// One story card's content. Built from the snapshot by [buildUnpackedCards];
/// a card whose data is missing is simply never built.
class UnpackedCardData {
  const UnpackedCardData({
    required this.id,
    required this.background,
    required this.eyebrow,
    required this.headline,
    this.detail,
    this.james,
    this.body,
    this.decoration,
  });

  final String id;
  final Color background;
  final String eyebrow;
  final String headline;
  final String? detail;
  final String? james;
  final Widget? body;

  /// Fills the space left under the text (a map, or a faint illustration).
  /// Dropped when the text leaves too little room for it.
  final Widget? decoration;
}

String _pct(int p, String what) => 'More $what than ${_n(p)}% of players.';

final NumberFormat _grouped = NumberFormat.decimalPattern('en_GB');

/// [v] with thousands separators: 9,840.
String _fmt(int v) => _grouped.format(v);

// Card text marks each count it shows, so the count can run up from 0 as
// the card comes in ([_CountUpText]) while years, dates and box references
// stay put. A mark is the number between two private-use characters.
const String _numOpen = '\uE000';
const String _numClose = '\uE001';
final RegExp _numMark = RegExp('$_numOpen(-?\\d+)$_numClose');

/// A count in card text: shown as [v] with thousands separators, and
/// animated up from 0 when the card appears.
String _n(int v) => '$_numOpen$v$_numClose';

/// Card text with each count at [t] (0–1) of its value.
String _countUp(String text, double t) => text.replaceAllMapped(
    _numMark, (m) => _fmt((int.parse(m[1]!) * t).round()));

/// Card text as it finally reads, for tests and screen readers.
@visibleForTesting
String unpackedPlainText(String text) => _countUp(text, 1);

String _plural(int n, String one, String many) =>
    '${_n(n)} ${n == 1 ? one : many}';

/// The text that travels with the shared image. Like every other share card
/// it carries the generic, campaign-tagged [kShareLinkUrl] rather than the
/// sharer's invite link: a share is public, and the two-way friend add stays
/// with the Friends screen's invite.
String unpackedShareText(int year) =>
    'My $year Postboxes Unpacked 📮 Hunting royal postboxes on '
    'The Postbox Game. Claim your postboxes: $kShareLinkUrl';

/// The ordered story for [recap]. Pure (aside from James's random variants)
/// so tests can assert which cards appear for a given snapshot.
/// Where [today] sits against [year]'s Christmas posting dates. The last
/// second-class day is the eve of the recap's window opening.
@visibleForTesting
ChristmasPost unpackedChristmasPost(String today, UnpackedSummary summary) {
  final opens = DateTime.tryParse(summary.availableFrom);
  if (opens == null) return ChristmasPost.after;
  final y = opens.year;
  final cutoff = _ymd(opens.subtract(const Duration(days: 1)));
  if (today.compareTo('$y-10-01') >= 0 && today.compareTo(cutoff) <= 0) {
    return ChristmasPost.before;
  }
  if (today.compareTo(cutoff) > 0 &&
      today.compareTo(summary.lastFirstClass) <= 0) {
    return ChristmasPost.firstClass;
  }
  if (today.compareTo(summary.lastFirstClass) > 0 &&
      today.compareTo('$y-12-24') <= 0) {
    return ChristmasPost.lastMinute;
  }
  return ChristmasPost.after;
}

String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// The ordered story for [recap]. [today] (London, "YYYY-MM-DD") picks the
/// guide's Christmas-post line; it defaults to the real date.
List<UnpackedCardData> buildUnpackedCards(UnpackedRecap recap,
    {String? today}) {
  final s = recap.stats;
  final sum = recap.summary;
  final cards = <UnpackedCardData>[
    UnpackedCardData(
      id: 'intro',
      background: royalNavy,
      eyebrow: 'THE POSTBOX GAME',
      headline: 'Your ${s.year}\nPostboxes\nUnpacked',
      detail: s.throughDate == null
          ? null
          : s.complete
              ? 'Your year up to ${_longDate(s.throughDate!)}, the last day '
                  'for second-class Christmas post.'
              : 'Your year so far, up to ${_prettyDate(s.throughDate!)}.',
      james: JamesMessages.unpackedIntro(
        s.year,
        christmas: unpackedChristmasPost(today ?? todayLondon(), sum),
        lastSecondClass: () {
          final opens = DateTime.tryParse(sum.availableFrom);
          return opens == null
              ? 'Friday 18 December'
              : _longDate(_ymd(opens.subtract(const Duration(days: 1))));
        }(),
        lastFirstClass: _longDate(sum.lastFirstClass),
      ),
      decoration: const _Watermark.svg('assets/postbox.svg'),
    ),
    UnpackedCardData(
      id: 'totals',
      background: postalRed,
      eyebrow: 'THIS YEAR YOU FOUND',
      headline: _plural(s.uniquePostboxes, 'postbox', 'postboxes'),
      detail: [
        '${_plural(s.totalPoints, 'point', 'points')} across '
            '${_plural(s.daysActive, 'day', 'days')} out and about.',
        if (s.percentileBoxes >= 50) _pct(s.percentileBoxes, 'postboxes'),
      ].join(' '),
      james: JamesMessages.unpackedTotals(s.uniquePostboxes),
      // Where they were found, county by county.
      decoration: s.countyBoxes.isEmpty
          ? const _Watermark.svg('assets/postbox.svg')
          : _countyMap(_strengths(s.countyBoxes)),
    ),
  ];

  final rarest = s.rarestMonarch;
  if (rarest != null && rarest != MonarchInfo.plainKey) {
    cards.add(UnpackedCardData(
      id: 'rarest',
      background: const Color(0xFF3A2A00),
      eyebrow: 'YOUR RAREST FIND',
      headline: MonarchInfo.labels[rarest] ?? rarest,
      detail: [
        'Worth ${_plural(s.rarestPoints, 'point', 'points')}'
            '${s.rarestReference != null ? ' (box ${s.rarestReference})' : ''}.',
        if (s.rarestDate != null) 'Found on ${_longDate(s.rarestDate!)}.',
      ].join(' '),
      james: JamesMessages.unpackedRarest(rarest),
      decoration: s.rarestCounty != null
          ? _countyMap({s.rarestCounty!: 1}, focus: {s.rarestCounty!})
          : const _Watermark.icon(Icons.workspace_premium_outlined),
    ));
  }

  if (s.monarchCounts.isNotEmpty) {
    // A collection: which of the known cyphers the player has, with plain
    // boxes as a footnote (they aren't a cypher) and the rest still to find.
    final cyphers = [
      for (final e in s.monarchCounts)
        if (e.key != MonarchInfo.plainKey) e,
    ];
    final plain = s.monarchCounts
        .where((e) => e.key == MonarchInfo.plainKey)
        .fold<int>(0, (a, e) => a + e.value);
    final have = {for (final e in cyphers) e.key};
    final collected = MonarchInfo.all.where(have.contains).length;
    final missing = [
      for (final m in MonarchInfo.all)
        if (!have.contains(m)) cypherShortName(m),
    ];
    cards.add(UnpackedCardData(
      id: 'monarchs',
      background: const Color(0xFF14365C),
      eyebrow: 'YOUR ROYAL ROLL-CALL',
      headline: '${_n(collected)} of ${MonarchInfo.all.length} cyphers',
      detail: missing.isEmpty ? 'The full set! Every cypher collected.' : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Every cypher collected, so the rare ones (always the smallest
          // counts) aren't cut off the bottom.
          if (cyphers.isNotEmpty) _MonarchBars(counts: cyphers),
          if (plain > 0)
            _Note('Plus ${_plural(plain, 'plain box', 'plain boxes')} '
                'with no cypher.'),
          if (missing.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            _TitledText(
              title: 'Still to find',
              text: missing.length == MonarchInfo.all.length
                  ? 'Every one of them. Happy hunting!'
                  : missing.join(', '),
            ),
          ],
        ],
      ),
      james: JamesMessages.unpackedMonarchs.resolve(),
    ));
  }

  if (s.busiestMonth > 0) {
    final month = monthNames[s.busiestMonth - 1];
    cards.add(UnpackedCardData(
      id: 'month',
      background: const Color(0xFF5B1A6E),
      eyebrow: 'YOUR BUSIEST MONTH',
      headline: month,
      detail: [
        '${_plural(s.busiestMonthClaims, 'claim', 'claims')} that month.',
      ].join(' '),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (s.monthCounts.isNotEmpty) ...[
            _BarChart(
              values: s.monthCounts,
              labels: const [
                'J',
                'F',
                'M',
                'A',
                'M',
                'J',
                'J',
                'A',
                'S',
                'O',
                'N',
                'D'
              ],
              showValues: false,
              semanticsLabel: 'Claims by month: ${[
                for (final (i, v) in s.monthCounts.indexed)
                  '${monthNames[i]} ${_fmt(v)}'
              ].join(', ')}',
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
          if (s.busiestDays.length >= 2)
            _InfoRows(title: 'Busiest days', rows: [
              for (final d in s.busiestDays)
                (
                  _longDate(d.date),
                  '${_plural(d.claims, 'box', 'boxes')} · '
                      '${_n(d.points)} pts'
                ),
            ]),
        ],
      ),
      james: JamesMessages.unpackedBusiestMonth(month),
    ));
  }

  final weekPoints = s.weekdayPoints.fold<int>(0, (a, b) => a + b);
  if (weekPoints > 0) {
    var best = 0;
    for (var i = 1; i < s.weekdayPoints.length; i++) {
      if (s.weekdayPoints[i] > s.weekdayPoints[best]) best = i;
    }
    final day = weekdayNames[best];
    cards.add(UnpackedCardData(
      id: 'weekday',
      background: const Color(0xFF0E4D64),
      eyebrow: 'DAYS OF THE WEEK',
      headline: '${day}s',
      detail: '${_plural(s.weekdayPoints[best], 'point', 'points')} on '
          '${day}s, more than any other day of the week.',
      body: _BarChart(
        values: s.weekdayPoints,
        labels: [for (final d in weekdayNames) d.substring(0, 3)],
        semanticsLabel: 'Points by day of the week: ${[
          for (final (i, v) in s.weekdayPoints.indexed)
            '${weekdayNames[i]} ${_fmt(v)}'
        ].join(', ')}',
      ),
      james: JamesMessages.unpackedWeekday(day),
    ));
  }

  if (s.longestStreakDays > 1) {
    // Friends whose names loaded, plus the player, longest first (the
    // player goes above a friend on the same number).
    final friends = [
      for (final f in s.friendStreaks)
        if (recap.friendNames[f.uid] != null)
          (recap.friendNames[f.uid]!, f.days),
    ];
    // (name, days, isYou), longest first; the player goes above a friend
    // on the same number.
    final ranked = [
      for (final (name, days) in friends) (name, days, false),
      (_you, s.longestStreakDays, true),
    ]..sort((a, b) {
        final c = b.$2.compareTo(a.$2);
        if (c != 0) return c;
        return a.$3 ? -1 : (b.$3 ? 1 : 0);
      });
    cards.add(UnpackedCardData(
      id: 'streak',
      background: const Color(0xFF7A3300),
      eyebrow: 'YOUR LONGEST STREAK',
      headline: _plural(s.longestStreakDays, 'day', 'days'),
      detail: [
        if (s.longestStreakStart != null && s.longestStreakEnd != null)
          'From ${_dateRange(s.longestStreakStart!, s.longestStreakEnd!)}.',
        if (s.percentileStreak >= 50) _pct(s.percentileStreak, 'days in a row'),
      ].join(' ').emptyToNull,
      body: friends.isEmpty
          ? null
          : _InfoRows(
              title: 'You and your friends',
              highlightIndex: ranked.indexWhere((r) => r.$3),
              rows: [
                for (final (name, days, _) in ranked)
                  (name, _plural(days, 'day', 'days')),
              ],
            ),
      james: JamesMessages.unpackedStreak(s.longestStreakDays),
      decoration: const _Watermark.icon(Icons.local_fire_department),
    ));
  }

  if (s.topFriendsDays > 0 || s.topEveryoneDays > 0) {
    final friends = s.topFriendsDays;
    final everyone = s.topEveryoneDays;
    cards.add(UnpackedCardData(
      id: 'top',
      background: const Color(0xFF3D1F6B),
      eyebrow: 'DAYS AT THE TOP',
      headline: _plural(friends > 0 ? friends : everyone, 'day', 'days'),
      detail: friends > 0
          ? 'Top among your friends on ${_plural(friends, 'day', 'days')}'
              '${everyone > 0 ? ', and top of everyone on ${_n(everyone)}!' : '.'}'
          : 'Top of everyone who played on ${_plural(everyone, 'day', 'days')}!',
      body: const _Note('The day\'s highest points score. Ties count, and a '
          'day only counts when someone else scored too.'),
      james: JamesMessages.unpackedTopScorer(everyone: s.topEveryoneDays > 0),
      decoration: const _Watermark.icon(Icons.leaderboard_outlined),
    ));
  }

  if (s.topCountyName != null) {
    cards.add(UnpackedCardData(
      id: 'county',
      background: const Color(0xFF1B5E20),
      eyebrow: 'YOUR HOME TURF',
      headline: countyDisplayName(s.topCountyName!),
      detail: [
        s.uniquePostboxes <= 1
            ? 'Your postbox was here.'
            : s.topCountyBoxes >= s.uniquePostboxes
                ? 'All ${_n(s.uniquePostboxes)} of your postboxes were here.'
                : '${_n(s.topCountyBoxes)} of your '
                    '${_plural(s.uniquePostboxes, 'postbox', 'postboxes')} '
                    'were here.',
        if (s.countiesVisited > 1)
          'You hunted in ${_plural(s.countiesVisited, 'county', 'counties')}.',
      ].join(' '),
      body: s.otherCounties.isEmpty
          ? null
          : _InfoRows(title: 'Also on your round', stacked: true, rows: [
              for (final c in s.otherCounties)
                (
                  countyDisplayName(c.name),
                  '${_plural(c.uniquePostboxes, 'box', 'boxes')} · '
                      '${_plural(c.otherPlayers, 'other player hunts', 'other players hunt')} here'
                ),
            ]),
      james: JamesMessages.unpackedCounty(countyDisplayName(s.topCountyName!)),
      decoration: _countyMap(
        {
          for (final c in s.otherCounties) c.name: 0.4,
          s.topCountyName!: 1,
        },
        focus: {s.topCountyName!, for (final c in s.otherCounties) c.name},
      ),
    ));
  }

  if (s.favouritePostboxes.isNotEmpty) {
    final top = s.favouritePostboxes.first;
    final cypher = top.monarch == MonarchInfo.plainKey
        ? 'A plain box'
        : (MonarchInfo.labels[top.monarch] ?? top.monarch);
    cards.add(UnpackedCardData(
      id: 'favourite',
      background: const Color(0xFF8A1538),
      eyebrow: 'YOUR FAVOURITE POSTBOX',
      headline: _favouriteName(top),
      detail: 'Claimed on ${_plural(top.claims, 'day', 'days')}. '
          '$cypher${top.reference != null && top.county != null ? ', in ${countyDisplayName(top.county!)}' : ''}.'
          '${top.fans <= 1 ? ' Nobody else claimed it all year.' : top.topFan ? ' Nobody claimed it more than you.' : ''}',
      body: s.favouritePostboxes.length < 2
          ? null
          : _InfoRows(title: 'Also a favourite', rows: [
              for (final b in s.favouritePostboxes.skip(1))
                (_favouriteName(b), _plural(b.claims, 'day', 'days')),
            ]),
      james: JamesMessages.unpackedFavourite(top.claims),
      decoration: top.county != null
          ? _countyMap(
              {
                for (final b in s.favouritePostboxes.skip(1))
                  if (b.county != null) b.county!: 0.4,
                top.county!: 1,
              },
              focus: {top.county!},
            )
          : const _Watermark.svg('assets/postbox.svg'),
    ));
  }

  if (sum.players > 1) {
    final others = sum.players - 1;
    final h = sum.highlights;
    cards.add(UnpackedCardData(
      id: 'community',
      background: royalNavy,
      eyebrow: 'TOGETHER',
      headline: _plural(sum.uniquePostboxes, 'postbox', 'postboxes'),
      detail:
          'Found by you and ${_plural(others, 'other player', 'other players')} '
          'this year'
          '${(h?.countiesCovered ?? 0) > 0 ? ', across ${_plural(h!.countiesCovered, 'county', 'counties')}.' : '.'}',
      body: _InfoRows(stacked: true, rows: [
        ('Claims made', _n(sum.totalClaims)),
        if (h?.rarestCypher != null)
          (
            'Rarest cypher found',
            '${MonarchInfo.labels[h!.rarestCypher] ?? h.rarestCypher} · '
                '${_plural(h.rarestCypherBoxes, 'box', 'boxes')}'
          ),
        if ((h?.longestStreak ?? 0) > 1)
          (
            'Longest streak anyone managed',
            _plural(h!.longestStreak, 'day', 'days')
          ),
        if (h?.busiestDayDate != null)
          (
            'Busiest day for everyone',
            '${_longDate(h!.busiestDayDate!)} · '
                '${_plural(h.busiestDayClaims, 'claim', 'claims')}'
          ),
        if ((h?.daysSoFar ?? 0) > 0)
          (
            'Days with a claim',
            'Someone was out hunting on ${_n(h!.daysWithClaims)} of '
                '${_n(h.daysSoFar)} days'
          ),
      ]),
      james: JamesMessages.unpackedCommunity.resolve(),
      decoration: (h?.sharedCounties.isNotEmpty ?? false)
          ? _countyMap({for (final c in h!.sharedCounties) c: 0.6})
          : null,
    ));
  }

  // The jokey award: a podium of the player and their friends by days out
  // hunting (then boxes found). Needs at least one friend whose name loaded.
  final award = unpackedAward(recap);
  if (award != null) {
    cards.add(UnpackedCardData(
      id: 'award',
      background: const Color(0xFF1C1407),
      eyebrow: 'AND NOW, THE AWARDS',
      headline: s.year == 2026
          ? 'The Inaugural\nMike H Award'
          : 'The ${s.year}\nMike H Award',
      detail: 'For dedication in the hunt for postboxes, among you and your '
          'friends. Judged on days out hunting.',
      body: _PodiumSteps(
        steps: [
          for (final e in award.field.take(3))
            (e.name, _plural(e.days, 'day', 'days'), e.you),
        ],
        ownPlace: award.place >= 3
            ? 'You came ${_ordinal(award.place + 1)}, with '
                '${_plural(s.daysActive, 'day', 'days')} out hunting.'
            : null,
      ),
      james: JamesMessages.unpackedAward(award.place),
    ));
  }

  cards.add(UnpackedCardData(
    id: 'share',
    background: royalNavy,
    eyebrow: 'THAT WAS YOUR YEAR',
    headline: 'Share it',
    james: JamesMessages.unpackedOutro.resolve(),
  ));
  return cards;
}

const String _you = 'You';

/// One entrant in the award: name, days out hunting, boxes found, the player?
typedef AwardEntrant = ({String name, int days, int boxes, bool you});

/// The Mike H Award field: the player and every friend whose name loaded,
/// by days out hunting, then boxes found (the player first on a tie), and
/// the player's place (0 = gold). Null when no friend qualifies.
({List<AwardEntrant> field, int place})? unpackedAward(UnpackedRecap recap) {
  final s = recap.stats;
  final friends = <AwardEntrant>[
    for (final f in s.friendAwards)
      if (recap.friendNames[f.uid] != null)
        (
          name: recap.friendNames[f.uid]!,
          days: f.daysActive,
          boxes: f.uniquePostboxes,
          you: false
        ),
  ];
  if (friends.isEmpty) return null;
  final field = [
    ...friends,
    (name: _you, days: s.daysActive, boxes: s.uniquePostboxes, you: true),
  ]..sort((a, b) {
      final c = b.days.compareTo(a.days);
      if (c != 0) return c;
      final d = b.boxes.compareTo(a.boxes);
      if (d != 0) return d;
      return a.you ? -1 : (b.you ? 1 : 0);
    });
  return (field: field, place: field.indexWhere((e) => e.you));
}

/// The medal for a podium [place] (0–2), else null.
String? unpackedMedal(int place) =>
    place >= 0 && place < _medals.length ? _medals[place] : null;

String _ordinal(int n) {
  final teen = n % 100 >= 11 && n % 100 <= 13;
  final suffix = teen
      ? 'th'
      : switch (n % 10) { 1 => 'st', 2 => 'nd', 3 => 'rd', _ => 'th' };
  return '$n$suffix';
}

/// "14 to 25 June", or "28 May to 8 June" across a month end.
String _dateRange(String start, String end) {
  final a = DateTime.tryParse(start);
  final b = DateTime.tryParse(end);
  if (a == null || b == null) return '$start to $end';
  return a.month == b.month
      ? '${a.day} to ${_prettyDate(end)}'
      : '${_prettyDate(start)} to ${_prettyDate(end)}';
}

extension on String {
  String? get emptyToNull => isEmpty ? null : this;
}

/// Box counts per county → map strengths (0.2–1), square-rooted so a
/// county with a handful of boxes still shows next to a home county.
Map<String, double> _strengths(Map<String, int> counts) {
  final max = counts.values.fold<int>(1, (m, v) => v > m ? v : m);
  return {
    for (final e in counts.entries)
      e.key: (0.2 + 0.8 * (e.value / max)).clamp(0.2, 1.0).toDouble(),
  };
}

const List<String> _medals = ['Gold', 'Silver', 'Bronze'];

const Map<String, Color> _medalColours = UnpackedShareCard.medalColours;

/// A favourite box's name: its reference, else where it is.
String _favouriteName(UnpackedFavourite b) => b.reference != null
    ? 'Box ${b.reference}'
    : b.county != null
        ? 'A box in ${countyDisplayName(b.county!)}'
        : 'One special box';

/// "Saturday 20 June" for a "YYYY-MM-DD" date.
String _longDate(String ymd) {
  final d = DateTime.tryParse(ymd);
  return d == null ? ymd : '${weekdayNames[d.weekday - 1]} ${_prettyDate(ymd)}';
}

String _prettyDate(String ymd) {
  final m = int.tryParse(ymd.substring(5, 7)) ?? 0;
  final d = int.tryParse(ymd.substring(8, 10)) ?? 0;
  if (m < 1 || m > 12 || d < 1) return ymd;
  return '$d ${monthNames[m - 1]}';
}

/// Full-screen, story-style "Your Postboxes Unpacked" recap.
///
/// Tap the right two-thirds to advance, the left third to go back; hold to
/// pause. Cards auto-advance unless the platform asks for reduced motion.
/// Pass [recap] when the caller already loaded it (the Home menu does);
/// otherwise the screen loads it for the signed-in user (deep link).
class UnpackedScreen extends StatefulWidget {
  const UnpackedScreen({
    super.key,
    this.recap,
    this.repository,
    this.uid,
    this.today,
  });

  final UnpackedRecap? recap;
  final UnpackedRepository? repository;
  final String? uid;

  /// London date ("YYYY-MM-DD") for the date-dependent lines; the real date
  /// when null. For tests and previews.
  final String? today;

  static const Duration cardDuration = Duration(seconds: 7);

  @override
  State<UnpackedScreen> createState() => _UnpackedScreenState();
}

class _UnpackedScreenState extends State<UnpackedScreen>
    with TickerProviderStateMixin {
  late final AnimationController _progress =
      AnimationController(vsync: this, duration: UnpackedScreen.cardDuration)
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed) _next();
        });
  // Runs each time a card comes in: counts run up, bars grow, lists fade in.
  late final AnimationController _entrance =
      AnimationController(vsync: this, duration: _entranceDuration);
  static const Duration _entranceDuration = Duration(milliseconds: 1400);
  final PageController _pages = PageController();
  final GlobalKey _shareKey = GlobalKey();

  UnpackedRecap? _recap;
  List<UnpackedCardData> _cards = const [];
  bool _loading = false;
  bool _sharing = false;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    if (widget.recap != null) {
      _setRecap(widget.recap!);
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    String? uid = widget.uid;
    try {
      uid ??= FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {}
    final recap = uid == null
        ? null
        : await (widget.repository ?? UnpackedRepository()).load(uid);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (recap != null) _setRecap(recap);
    });
  }

  void _setRecap(UnpackedRecap recap) {
    _recap = recap;
    _cards = buildUnpackedCards(recap, today: widget.today);
    unawaited(Analytics.unpackedOpened(year: recap.year));
    WidgetsBinding.instance.addPostFrameCallback((_) => _restartTimer());
  }

  bool get _reduceMotion =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  bool get _autoAdvance => mounted && !_reduceMotion;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced motion: every card shows its final numbers straight away.
    if (_reduceMotion) {
      _entrance.value = 1;
    }
  }

  void _startEntrance() {
    if (!mounted) return;
    if (_reduceMotion) {
      _entrance.value = 1;
    } else {
      _entrance.forward(from: 0);
    }
  }

  void _restartTimer() {
    if (!mounted) return;
    _startEntrance();
    _progress.reset();
    // The final (share) card waits for the player.
    if (_autoAdvance && _index < _cards.length - 1) _progress.forward();
  }

  void _goTo(int i) {
    if (i < 0 || i >= _cards.length) return;
    setState(() => _index = i);
    _pages.jumpToPage(i);
    _restartTimer();
  }

  void _next() => _goTo(_index + 1);
  void _previous() => _goTo(_index - 1);

  void _pause() => _progress.stop();
  void _resume() {
    if (_autoAdvance && _index < _cards.length - 1) _progress.forward();
  }

  Future<void> _share() async {
    final recap = _recap;
    if (recap == null || _sharing) return;
    setState(() => _sharing = true);
    try {
      // google_fonts loads at runtime: a capture taken before the font
      // arrives renders in the fallback face.
      await GoogleFonts.pendingFonts();
      await WidgetsBinding.instance.endOfFrame;
      final boundary = _shareKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return;
      // 3x, so the 360x640 card becomes a 1080x1920 PNG.
      final png = await renderShareCardPng(boundary);
      if (png == null) return;
      final fileName = 'postboxes-unpacked-${recap.year}.png';
      final result = await SharePlus.instance.share(ShareParams(
        files: [XFile.fromData(png, mimeType: 'image/png', name: fileName)],
        fileNameOverrides: [fileName],
        text: unpackedShareText(recap.year),
      ));
      if (result.status != ShareResultStatus.dismissed) {
        unawaited(Analytics.share(
          contentType: 'unpacked',
          itemId: '${recap.year}',
          method: result.raw.isNotEmpty ? result.raw : 'unknown',
          style: 'unpacked',
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not share right now.')),
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    _entrance.dispose();
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recap = _recap;
    if (recap == null) {
      return Scaffold(
        backgroundColor: royalNavy,
        appBar: AppBar(backgroundColor: royalNavy),
        body: Center(
          child: _loading
              ? const CircularProgressIndicator(color: Colors.white)
              : const Padding(
                  padding: EdgeInsets.all(AppSpacing.lg),
                  child: Text(
                    "Your Postboxes Unpacked isn't ready yet. "
                    'Check back just before Christmas!',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: 18),
                  ),
                ),
        ),
      );
    }

    final card = _cards[_index];
    return Scaffold(
      backgroundColor: card.background,
      body: SafeArea(
        child: Stack(
          children: [
            // Pages are driven by taps, not swipes, so the gesture layer
            // below owns every touch.
            _Entrance(
              animation: _entrance,
              child: PageView(
                controller: _pages,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final c in _cards)
                    c.id == 'share'
                        ? _ShareCardPage(
                            data: c,
                            stats: recap.stats,
                            medal: unpackedMedal(
                                unpackedAward(recap)?.place ?? -1),
                            shareKey: _shareKey,
                            sharing: _sharing,
                            onShare: _share,
                          )
                        : _StoryCard(data: c),
                ],
              ),
            ),
            if (card.id != 'share')
              Positioned.fill(
                child: Row(
                  children: [
                    Expanded(
                      child: _TapZone(
                        label: 'Previous card',
                        onTap: _previous,
                        onHoldStart: _pause,
                        onHoldEnd: _resume,
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: _TapZone(
                        label: 'Next card',
                        onTap: _next,
                        onHoldStart: _pause,
                        onHoldEnd: _resume,
                      ),
                    ),
                  ],
                ),
              ),
            Positioned(
              top: AppSpacing.sm,
              left: AppSpacing.md,
              right: AppSpacing.md,
              child: _ProgressBars(
                count: _cards.length,
                index: _index,
                progress: _progress,
              ),
            ),
            Positioned(
              top: AppSpacing.md,
              right: 0,
              child: IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
            if (card.id == 'share' && _index > 0)
              Positioned(
                top: AppSpacing.md,
                left: 0,
                child: IconButton(
                  tooltip: 'Previous card',
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: _previous,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TapZone extends StatelessWidget {
  const _TapZone({
    required this.label,
    required this.onTap,
    required this.onHoldStart,
    required this.onHoldEnd,
  });

  final String label;
  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPressStart: (_) => onHoldStart(),
        onLongPressEnd: (_) => onHoldEnd(),
      ),
    );
  }
}

class _ProgressBars extends StatelessWidget {
  const _ProgressBars({
    required this.count,
    required this.index,
    required this.progress,
  });

  final int count;
  final int index;
  final Animation<double> progress;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Row(
        children: [
          for (var i = 0; i < count; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: i == index
                      ? AnimatedBuilder(
                          animation: progress,
                          builder: (_, __) => LinearProgressIndicator(
                            value: progress.value,
                            minHeight: 3,
                            color: Colors.white,
                            backgroundColor: Colors.white24,
                          ),
                        )
                      : LinearProgressIndicator(
                          value: i < index ? 1 : 0,
                          minHeight: 3,
                          color: Colors.white,
                          backgroundColor: Colors.white24,
                        ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StoryCard extends StatelessWidget {
  const _StoryCard({required this.data});

  final UnpackedCardData data;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.xxl + AppSpacing.md, AppSpacing.lg, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The tap zones sit over the whole card, so it can't scroll:
          // content taller than the space (a long cypher roll-call on a
          // small phone, or any card in landscape) shrinks to fit instead
          // of being cut off. The decoration gets whatever room is left.
          Expanded(
            child: CustomMultiChildLayout(
              delegate: _CardLayout(),
              children: [
                LayoutId(
                  id: _CardSlot.content,
                  child: LayoutBuilder(
                    builder: (context, constraints) => FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: constraints.maxWidth,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              data.eyebrow,
                              style: GoogleFonts.plusJakartaSans(
                                color: postalGold,
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 2,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.md),
                            _CountUpText(
                              data.headline,
                              style: GoogleFonts.playfairDisplay(
                                color: Colors.white,
                                fontSize: 44,
                                height: 1.1,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (data.detail != null) ...[
                              const SizedBox(height: AppSpacing.md),
                              _CountUpText(
                                data.detail!,
                                style: GoogleFonts.plusJakartaSans(
                                  color: Colors.white.withValues(alpha: 0.9),
                                  fontSize: 18,
                                  height: 1.4,
                                ),
                              ),
                            ],
                            if (data.body != null) ...[
                              const SizedBox(height: AppSpacing.lg),
                              data.body!,
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (data.decoration != null)
                  LayoutId(id: _CardSlot.decoration, child: data.decoration!),
              ],
            ),
          ),
          if (data.james != null) _JamesSays(text: data.james!),
        ],
      ),
    );
  }
}

/// The current card's entrance (0 → 1), for everything that animates in.
class _Entrance extends InheritedWidget {
  const _Entrance({required this.animation, required super.child});

  final Animation<double> animation;

  /// The entrance, or a finished one outside a recap (e.g. a lone widget).
  static Animation<double> of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_Entrance>()?.animation ??
      kAlwaysCompleteAnimation;

  @override
  bool updateShouldNotify(_Entrance old) => old.animation != animation;
}

/// The part of the entrance from [start] to [end], eased.
Animation<double> _phase(BuildContext context, double start, double end) =>
    CurvedAnimation(
      parent: _Entrance.of(context),
      curve: Interval(start.clamp(0.0, 1.0), end.clamp(0.0, 1.0),
          curve: Curves.easeOutCubic),
    );

/// Card text whose counts run up from 0 as the card comes in. Text without
/// counts is drawn as plain [Text]. Screen readers get the final text.
class _CountUpText extends StatelessWidget {
  const _CountUpText(this.text, {this.style, this.textAlign});

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    if (!_numMark.hasMatch(text)) {
      return Text(text, style: style, textAlign: textAlign);
    }
    final t = _phase(context, 0, 0.75);
    return Semantics(
      label: unpackedPlainText(text),
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: t,
          builder: (context, _) =>
              Text(_countUp(text, t.value), style: style, textAlign: textAlign),
        ),
      ),
    );
  }
}

/// A list row that fades and slides in, a beat after the one above it.
class _Reveal extends StatelessWidget {
  const _Reveal({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final start = 0.15 + index * 0.08;
    final t = _phase(context, start, start + 0.4);
    return FadeTransition(
      opacity: t,
      child: SlideTransition(
        position:
            Tween(begin: const Offset(0, 0.35), end: Offset.zero).animate(t),
        child: child,
      ),
    );
  }
}

enum _CardSlot { content, decoration }

/// Lays the card's text out first, then gives the decoration the space
/// under it, or none when less than [minDecoration] is left.
class _CardLayout extends MultiChildLayoutDelegate {
  static const double minDecoration = 110;

  @override
  void performLayout(Size size) {
    final content = layoutChild(_CardSlot.content, BoxConstraints.loose(size));
    positionChild(_CardSlot.content, Offset.zero);
    if (hasChild(_CardSlot.decoration)) {
      final top = content.height + AppSpacing.md;
      final room = size.height - top - AppSpacing.sm;
      final fits = room >= minDecoration;
      layoutChild(_CardSlot.decoration,
          BoxConstraints.tight(fits ? Size(size.width, room) : Size.zero));
      positionChild(_CardSlot.decoration, Offset(0, fits ? top : size.height));
    }
  }

  @override
  bool shouldRelayout(_CardLayout oldDelegate) => false;
}

/// A large, faint illustration for a card's empty space.
class _Watermark extends StatelessWidget {
  const _Watermark.icon(this.icon) : svgAsset = null;
  const _Watermark.svg(this.svgAsset) : icon = null;

  final IconData? icon;
  final String? svgAsset;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Align(
        alignment: Alignment.bottomRight,
        child: LayoutBuilder(builder: (context, c) {
          final side = c.biggest.shortestSide.clamp(0.0, 260.0);
          return Opacity(
            opacity: 0.12,
            child: svgAsset != null
                ? SvgPicture.asset(
                    svgAsset!,
                    height: side,
                    colorFilter:
                        const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                  )
                : Icon(icon, size: side, color: Colors.white),
          );
        }),
      ),
    );
  }
}

/// A bar chart for a card: one bar per value, the biggest in gold. Values
/// show above the bars when [showValues], otherwise only the biggest one.
class _BarChart extends StatelessWidget {
  const _BarChart({
    required this.values,
    required this.labels,
    required this.semanticsLabel,
    this.showValues = true,
  });

  final List<int> values;
  final List<String> labels;
  final String semanticsLabel;
  final bool showValues;

  static const double _barMax = 110;

  @override
  Widget build(BuildContext context) {
    final max = values.fold<int>(0, (m, v) => v > m ? v : m);
    final small = GoogleFonts.plusJakartaSans(
        color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w700);
    return Semantics(
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: SizedBox(
          height: _barMax + 44,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final (i, v) in values.indexed)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    // Bars grow left to right, a little after each other.
                    child: AnimatedBuilder(
                      animation:
                          _phase(context, 0.05 + i * 0.03, 0.6 + i * 0.03),
                      builder: (context, _) {
                        final t =
                            _phase(context, 0.05 + i * 0.03, 0.6 + i * 0.03)
                                .value;
                        final top = v == max && v > 0;
                        return Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (showValues || top)
                              Text(
                                _fmt((v * t).round()),
                                maxLines: 1,
                                style: small.copyWith(
                                    color: top ? postalGold : Colors.white),
                              ),
                            const SizedBox(height: 4),
                            Container(
                              height: max == 0
                                  ? 0
                                  : (v / max * _barMax * t)
                                      .clamp(v > 0 && t > 0 ? 3 : 0, _barMax),
                              decoration: BoxDecoration(
                                color: top
                                    ? postalGold
                                    : Colors.white.withValues(alpha: 0.32),
                                borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(3)),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(labels[i], maxLines: 1, style: small),
                          ],
                        );
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The UK county map as a card decoration.
Widget _countyMap(Map<String, double> highlights,
        {Set<String> focus = const {}}) =>
    UkCountyMap(highlights: highlights, focus: focus);

class _JamesSays extends StatelessWidget {
  const _JamesSays({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const ExcludeSemantics(child: PostmanJames(size: 64)),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(AppSpacing.md - 4),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                text,
                style: const TextStyle(color: royalNavy, fontSize: 15),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MonarchBars extends StatelessWidget {
  const _MonarchBars({required this.counts});

  final List<MapEntry<String, int>> counts;

  @override
  Widget build(BuildContext context) {
    final max = counts.fold<int>(1, (m, e) => e.value > m ? e.value : m);
    return Column(
      children: [
        for (final (i, e) in counts.indexed)
          _Reveal(
            index: i,
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm + 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          MonarchInfo.labels[e.key] ?? e.key,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 15),
                        ),
                      ),
                      _CountUpText(
                        _n(e.value),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: AnimatedBuilder(
                      animation:
                          _phase(context, 0.1 + i * 0.06, 0.7 + i * 0.06),
                      builder: (context, _) => LinearProgressIndicator(
                        value: e.value /
                            max *
                            _phase(context, 0.1 + i * 0.06, 0.7 + i * 0.06)
                                .value,
                        minHeight: 8,
                        color: MonarchInfo.colors[e.key] ?? postalGold,
                        backgroundColor: Colors.white12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A short titled list on a story card: label on the left and value on the
/// right, or label above value when [stacked] (long labels and values).
/// The row at [highlightIndex] is picked out in gold.
class _InfoRows extends StatelessWidget {
  const _InfoRows({
    required this.rows,
    this.title,
    this.highlightIndex,
    this.stacked = false,
  });

  final List<(String, String)> rows;
  final String? title;

  /// The row to pick out in gold (the player's own, on "Longest streak").
  final int? highlightIndex;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final labelStyle = GoogleFonts.plusJakartaSans(
        color: Colors.white.withValues(alpha: 0.85), fontSize: 15);
    final valueStyle = GoogleFonts.plusJakartaSans(
        color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[
          Text(
            title!.toUpperCase(),
            style: GoogleFonts.plusJakartaSans(
              color: postalGold,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        for (final (i, (label, value)) in rows.indexed)
          _Reveal(
            index: i,
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm + 2),
              child: stacked
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label.toUpperCase(),
                          style: GoogleFonts.plusJakartaSans(
                            color: Colors.white70,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 2),
                        _CountUpText(value,
                            style: valueStyle.copyWith(fontSize: 18)),
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: Text(
                            label,
                            style: i == highlightIndex
                                ? valueStyle.copyWith(color: postalGold)
                                : labelStyle,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        // Wraps rather than overflows at large text sizes.
                        Flexible(
                          flex: 4,
                          child: _CountUpText(
                            value,
                            textAlign: TextAlign.end,
                            style: i == highlightIndex
                                ? valueStyle.copyWith(color: postalGold)
                                : valueStyle,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
      ],
    );
  }
}

/// A small muted line under a card's main content.
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: _CountUpText(
        text,
        style: GoogleFonts.plusJakartaSans(
            color: Colors.white.withValues(alpha: 0.75), fontSize: 14),
      ),
    );
  }
}

/// A gold small-caps title over a line of text.
class _TitledText extends StatelessWidget {
  const _TitledText({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: GoogleFonts.plusJakartaSans(
            color: postalGold,
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          text,
          style: GoogleFonts.plusJakartaSans(
              color: Colors.white, fontSize: 15, height: 1.35),
        ),
      ],
    );
  }
}

/// The award podium: gold on the tall middle step, silver to its left and
/// bronze to its right. The steps rise as the card comes in, bronze first
/// and gold last.
class _PodiumSteps extends StatelessWidget {
  const _PodiumSteps({required this.steps, this.ownPlace});

  /// (name, value, isYou), gold first: two or three of them.
  final List<(String, String, bool)> steps;

  /// The player's place when they're off the podium.
  final String? ownPlace;

  static const List<double> _heights = [118, 88, 64];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Sized by its content (the card shrinks to fit), so large text
        // can't overflow a fixed height.
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Left to right: silver, gold, bronze.
            for (final i in const [1, 0, 2])
              Expanded(
                child: i < steps.length
                    ? _step(context, i)
                    : const SizedBox.shrink(),
              ),
          ],
        ),
        if (ownPlace != null) ...[
          const SizedBox(height: AppSpacing.sm),
          _Note(ownPlace!),
        ],
      ],
    );
  }

  Widget _step(BuildContext context, int i) {
    final (name, value, you) = steps[i];
    final medal = _medals[i];
    final colour = _medalColours[medal]!;
    final start = 0.1 + (2 - i) * 0.15;
    final rise = _phase(context, start, start + 0.45);
    return Semantics(
      container: true,
      label: '$medal: $name, ${unpackedPlainText(value)}',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Icon(Icons.emoji_events, color: colour, size: i == 0 ? 34 : 26),
              const SizedBox(height: 2),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: GoogleFonts.plusJakartaSans(
                  color: you ? postalGold : Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              _CountUpText(
                value,
                textAlign: TextAlign.center,
                style: GoogleFonts.plusJakartaSans(
                    color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 6),
              AnimatedBuilder(
                animation: rise,
                builder: (context, _) => ClipRect(
                  child: Container(
                    height: _heights[i] * rise.value,
                    width: double.infinity,
                    alignment: Alignment.topCenter,
                    decoration: BoxDecoration(
                      color: colour.withValues(alpha: 0.9),
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(6)),
                    ),
                    child: _heights[i] * rise.value > 44
                        ? Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              '${i + 1}',
                              style: GoogleFonts.playfairDisplay(
                                color: const Color(0xFF1C1407),
                                fontSize: 28,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          )
                        : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShareCardPage extends StatelessWidget {
  const _ShareCardPage({
    required this.data,
    required this.stats,
    required this.shareKey,
    required this.sharing,
    required this.onShare,
    this.medal,
  });

  final UnpackedCardData data;
  final UnpackedStats stats;
  final String? medal;
  final GlobalKey shareKey;
  final bool sharing;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.xxl + AppSpacing.md, AppSpacing.lg, 0),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: FittedBox(
                child: RepaintBoundary(
                  key: shareKey,
                  child: UnpackedShareCard(stats: stats, medal: medal),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: postalGold,
                foregroundColor: Colors.black,
                minimumSize: const Size(0, 52),
              ),
              onPressed: sharing ? null : onShare,
              icon: sharing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.ios_share),
              label: const Text('Share my year'),
            ),
          ),
          if (data.james != null) ...[
            const SizedBox(height: AppSpacing.md),
            _JamesSays(text: data.james!),
          ],
        ],
      ),
    );
  }
}
