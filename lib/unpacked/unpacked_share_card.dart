import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/theme.dart';
import 'package:postbox_game/unpacked/unpacked_stats.dart';

/// The shareable 9:16 summary card. Laid out at a fixed logical size
/// ([logicalSize]) so the exported image is identical on every device;
/// [UnpackedScreen] captures it with `renderShareCardPng` (3x) → a
/// 1080 × 1920 PNG.
///
/// Shows only the player's own aggregate numbers (no location, no other
/// players' names), so sharing it publicly leaks nothing.
class UnpackedShareCard extends StatelessWidget {
  const UnpackedShareCard({super.key, required this.stats, this.medal});

  final UnpackedStats stats;

  /// "Gold", "Silver" or "Bronze" when the player placed in the Mike H
  /// Award; shown as a row with a medal-coloured trophy.
  final String? medal;

  static const Map<String, Color> medalColours = {
    'Gold': Color(0xFFFFC83D),
    'Silver': Color(0xFFC9CED6),
    'Bronze': Color(0xFFD08A4C),
  };

  static const Size logicalSize = Size(360, 640);
  static const double _padding = AppSpacing.lg + 4;

  @override
  Widget build(BuildContext context) {
    final n = NumberFormat.decimalPattern('en_GB');
    // (label, value, trophy colour for the award row).
    final rows = <(String, String, Color?)>[
      ('Postboxes found', n.format(stats.uniquePostboxes), null),
      ('Points scored', n.format(stats.totalPoints), null),
      if (stats.longestStreakDays > 1)
        ('Longest streak', '${stats.longestStreakDays} days', null),
      if (stats.rarestMonarch != null &&
          stats.rarestMonarch != MonarchInfo.plainKey)
        ('Rarest find', cypherShortName(stats.rarestMonarch!), null),
      if (stats.topCountyName != null)
        ('Top county', countyDisplayName(stats.topCountyName!), null),
      if (medal != null && medalColours.containsKey(medal))
        ('Mike H Award', medal!, medalColours[medal]),
    ];

    return SizedBox.fromSize(
      size: logicalSize,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [postalRed, royalNavy],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(_padding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'THE POSTBOX GAME',
                style: GoogleFonts.plusJakartaSans(
                  color: postalGold,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'My ${stats.year}\nPostboxes\nUnpacked',
                style: GoogleFonts.playfairDisplay(
                  color: Colors.white,
                  fontSize: 40,
                  height: 1.05,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              // The stat block scales down (never overflows) when a long
              // county name or big numbers make it taller than the space
              // left, so the exported image always keeps its fixed size.
              Expanded(
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.bottomLeft,
                    child: SizedBox(
                      width: logicalSize.width - _padding * 2,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final (label, value, trophy) in rows)
                            Padding(
                              padding:
                                  const EdgeInsets.only(bottom: AppSpacing.md),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    label.toUpperCase(),
                                    style: GoogleFonts.plusJakartaSans(
                                      color: Colors.white70,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 1.5,
                                    ),
                                  ),
                                  Row(
                                    children: [
                                      if (trophy != null) ...[
                                        Icon(Icons.emoji_events,
                                            color: trophy, size: 28),
                                        const SizedBox(width: AppSpacing.xs),
                                      ],
                                      Flexible(
                                        child: Text(
                                          value,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: GoogleFonts.plusJakartaSans(
                                            color: trophy ?? Colors.white,
                                            fontSize: 28,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          if (stats.percentileBoxes >= 50)
                            Text(
                              'More postboxes than ${stats.percentileBoxes}% '
                              'of players',
                              style: GoogleFonts.plusJakartaSans(
                                color: postalGold,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                        ],
                      ),
                    ),
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
