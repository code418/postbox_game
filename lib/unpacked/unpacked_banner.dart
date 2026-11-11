import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:postbox_game/theme.dart';

/// SharedPreferences key: the "recap is ready" banner was opened or
/// dismissed for [year], so it doesn't come back.
String unpackedBannerDoneKey(int year) => 'unpacked_banner_done_$year';

/// The one-time "Your {year} Postboxes Unpacked is ready" banner at the top
/// of the Nearby tab: the recap's front door, more visible than the menu.
class UnpackedReadyBanner extends StatelessWidget {
  const UnpackedReadyBanner({
    super.key,
    required this.year,
    required this.onOpen,
    required this.onDismiss,
  });

  final int year;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: royalNavy,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.md, AppSpacing.sm, AppSpacing.xs, AppSpacing.sm),
          child: Row(
            children: [
              const Icon(Icons.card_giftcard, color: postalGold),
              const SizedBox(width: AppSpacing.sm + 4),
              Expanded(
                child: Text(
                  'Your $year Postboxes Unpacked is ready',
                  style: GoogleFonts.plusJakartaSans(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              // A finite minimum size: the theme's buttons default to an
              // infinite width, which a Row can't lay out.
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: postalGold,
                  foregroundColor: Colors.black,
                  minimumSize: const Size(0, 40),
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                ),
                onPressed: onOpen,
                child: const Text('Open'),
              ),
              IconButton(
                tooltip: 'Dismiss',
                icon: const Icon(Icons.close, color: Colors.white70),
                onPressed: onDismiss,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
