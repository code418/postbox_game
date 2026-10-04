import 'dart:async';
import 'dart:ui' as ui;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:postbox_game/analytics_service.dart';
import 'package:postbox_game/james_messages.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/postman_james.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/unpacked/unpacked_repository.dart';
import 'package:postbox_game/unpacked/unpacked_share_card.dart';
import 'package:postbox_game/unpacked/unpacked_stats.dart';
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
  });

  final String id;
  final Color background;
  final String eyebrow;
  final String headline;
  final String? detail;
  final String? james;
  final Widget? body;
}

String _pct(int p, String what) => 'More $what than $p% of players.';

/// The ordered story for [recap]. Pure (aside from James's random variants)
/// so tests can assert which cards appear for a given snapshot.
List<UnpackedCardData> buildUnpackedCards(UnpackedRecap recap) {
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
          : 'Your year so far, up to ${_prettyDate(s.throughDate!)}.',
      james: JamesMessages.unpackedIntro(s.year),
    ),
    UnpackedCardData(
      id: 'totals',
      background: postalRed,
      eyebrow: 'THIS YEAR YOU FOUND',
      headline:
          '${s.uniquePostboxes} ${s.uniquePostboxes == 1 ? 'postbox' : 'postboxes'}',
      detail: [
        '${s.totalPoints} points across ${s.daysActive} '
            '${s.daysActive == 1 ? 'day' : 'days'} out and about.',
        if (s.percentileBoxes >= 50) _pct(s.percentileBoxes, 'postboxes'),
      ].join(' '),
      james: JamesMessages.unpackedTotals(s.uniquePostboxes),
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
        'Worth ${s.rarestPoints} points',
        if (s.rarestReference != null) '(box ${s.rarestReference})',
      ].join(' '),
      james: JamesMessages.unpackedRarest.resolve(),
    ));
  }

  if (s.monarchCounts.isNotEmpty) {
    cards.add(UnpackedCardData(
      id: 'monarchs',
      background: const Color(0xFF14365C),
      eyebrow: 'YOUR ROYAL ROLL-CALL',
      headline: '${s.monarchCounts.length} '
          '${s.monarchCounts.length == 1 ? 'cypher' : 'cyphers'}',
      body: _MonarchBars(counts: s.monarchCounts.take(5).toList()),
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
        '${s.busiestMonthClaims} '
            '${s.busiestMonthClaims == 1 ? 'claim' : 'claims'}.',
        if (s.favouriteWeekday > 0)
          'Favourite day for a wander: ${weekdayNames[s.favouriteWeekday - 1]}.',
      ].join(' '),
      james: JamesMessages.unpackedBusiestMonth(month),
    ));
  }

  if (s.longestStreakDays > 1) {
    cards.add(UnpackedCardData(
      id: 'streak',
      background: const Color(0xFF7A3300),
      eyebrow: 'YOUR LONGEST STREAK',
      headline: '${s.longestStreakDays} days',
      detail: s.percentileStreak >= 50
          ? _pct(s.percentileStreak, 'days in a row')
          : null,
      james: JamesMessages.unpackedStreak(s.longestStreakDays),
    ));
  }

  if (s.topCountyName != null) {
    cards.add(UnpackedCardData(
      id: 'county',
      background: const Color(0xFF1B5E20),
      eyebrow: 'YOUR HOME TURF',
      headline: s.topCountyName!,
      detail: '${s.topCountyBoxes} '
          '${s.topCountyBoxes == 1 ? 'postbox' : 'postboxes'} there'
          '${s.countiesVisited > 1 ? ', out of ${s.countiesVisited} counties visited.' : '.'}',
      james: JamesMessages.unpackedCounty(s.topCountyName!),
    ));
  }

  if (sum.players > 1) {
    final others = sum.players - 1;
    cards.add(UnpackedCardData(
      id: 'community',
      background: royalNavy,
      eyebrow: 'TOGETHER',
      headline: '${sum.uniquePostboxes} postboxes',
      detail: 'Found by you and $others other '
          '${others == 1 ? 'player' : 'players'} this year'
          '${sum.topMonarch != null ? ', with ${MonarchInfo.labels[sum.topMonarch] ?? sum.topMonarch} the most-claimed cypher.' : '.'}',
      james: JamesMessages.unpackedCommunity.resolve(),
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
  const UnpackedScreen({super.key, this.recap, this.repository, this.uid});

  final UnpackedRecap? recap;
  final UnpackedRepository? repository;
  final String? uid;

  static const Duration cardDuration = Duration(seconds: 7);

  @override
  State<UnpackedScreen> createState() => _UnpackedScreenState();
}

class _UnpackedScreenState extends State<UnpackedScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress =
      AnimationController(vsync: this, duration: UnpackedScreen.cardDuration)
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed) _next();
        });
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
    _cards = buildUnpackedCards(recap);
    unawaited(Analytics.unpackedOpened(year: recap.year));
    WidgetsBinding.instance.addPostFrameCallback((_) => _restartTimer());
  }

  bool get _autoAdvance =>
      mounted && !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);

  void _restartTimer() {
    if (!mounted) return;
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
      final boundary = _shareKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(
          pixelRatio: UnpackedShareCard.exportPixelRatio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (bytes == null) return;
      await SharePlus.instance.share(ShareParams(
        files: [
          XFile.fromData(bytes.buffer.asUint8List(), mimeType: 'image/png'),
        ],
        fileNameOverrides: ['postboxes-unpacked-${recap.year}.png'],
        text: 'My ${recap.year} Postboxes Unpacked 📮 #ThePostboxGame',
      ));
      unawaited(Analytics.unpackedShared(year: recap.year));
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
                    'Check back in December!',
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
            PageView(
              controller: _pages,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (final c in _cards)
                  c.id == 'share'
                      ? _ShareCardPage(
                          data: c,
                          stats: recap.stats,
                          shareKey: _shareKey,
                          sharing: _sharing,
                          onShare: _share,
                        )
                      : _StoryCard(data: c),
              ],
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
          Expanded(
            child: SingleChildScrollView(
              child: Column(
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
                  Text(
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
                    Text(
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
          if (data.james != null) _JamesSays(text: data.james!),
        ],
      ),
    );
  }
}

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
        for (final e in counts)
          Padding(
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
                        style:
                            const TextStyle(color: Colors.white, fontSize: 15),
                      ),
                    ),
                    Text(
                      '${e.value}',
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
                  child: LinearProgressIndicator(
                    value: e.value / max,
                    minHeight: 8,
                    color: MonarchInfo.colors[e.key] ?? postalGold,
                    backgroundColor: Colors.white12,
                  ),
                ),
              ],
            ),
          ),
      ],
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
  });

  final UnpackedCardData data;
  final UnpackedStats stats;
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
                  child: UnpackedShareCard(stats: stats),
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
