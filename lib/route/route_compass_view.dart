import 'dart:math';

import 'package:flutter/material.dart';
import 'package:postbox_game/fuzzy_compass.dart';

/// A composite widget that layers a precise destination arrow on top of the
/// existing [FuzzyCompass].
///
/// The fuzzy compass shows unclaimed/claimed sector densities (deliberately
/// imprecise, as always). The destination arrow overlay is precise — it points
/// from the compass centre toward [destinationBearingDegrees], rotated to
/// account for [deviceHeadingDegrees] so that it stays meaningful relative to
/// how the user is holding the device.
///
/// No streaming/state here — pure stateless widget. The caller must pass fresh
/// values whenever the heading or bearing changes.
class RouteCompassView extends StatelessWidget {
  /// 16-wind counts for unclaimed postboxes (N, NNE, NE, ...).
  final Map<String, int> compassCounts;

  /// 16-wind counts for postboxes already claimed today.
  final Map<String, int> claimedCompassCounts;

  /// Device heading in degrees (0 = N). Null when the compass sensor is not
  /// available; the compass and arrow are rendered without rotation.
  final double? deviceHeadingDegrees;

  /// Absolute bearing from the user's current position to the destination,
  /// in degrees (0 = N, clockwise).
  final double destinationBearingDegrees;

  const RouteCompassView({
    super.key,
    required this.compassCounts,
    required this.claimedCompassCounts,
    required this.deviceHeadingDegrees,
    required this.destinationBearingDegrees,
  });

  @override
  Widget build(BuildContext context) {
    // Angle of the destination arrow in the canvas coordinate system.
    // When the device heading is known, subtract it so the arrow stays
    // screen-relative (pointing toward the destination as seen on screen).
    final double arrowAngle = ((destinationBearingDegrees - (deviceHeadingDegrees ?? 0)) % 360) * pi / 180;

    return Stack(
      alignment: Alignment.center,
      children: [
        // Layer 1: fuzzy compass (shows rough sector info, handles heading rotation internally).
        FuzzyCompass(
          compassCounts: compassCounts,
          claimedCompassCounts: claimedCompassCounts,
          headingDegrees: deviceHeadingDegrees,
        ),

        // Layer 2: precise destination arrow, drawn over the compass rose.
        // Positioned at the centre of the compass card — the Card widget adds
        // padding so the arrow sits roughly in the middle of the circular disc.
        IgnorePointer(
          child: Padding(
            // Mirror the FuzzyCompass card internals: card padding + title rows
            // push the disc down by approximately 70 px from the card top.
            // We only need a rough alignment for T8; the precise layout can be
            // refined in T9 once the full live UI is assembled.
            padding: const EdgeInsets.only(top: 72),
            child: _DestinationArrow(angle: arrowAngle),
          ),
        ),
      ],
    );
  }
}

/// A small arrow icon rotated to point in [angle] radians (screen-relative,
/// 0 = up = North on screen when the compass is upright).
class _DestinationArrow extends StatelessWidget {
  final double angle;

  const _DestinationArrow({required this.angle});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Transform.rotate(
      angle: angle,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.90),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.20),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: const Icon(
          Icons.navigation,
          color: Colors.white,
          size: 20,
        ),
      ),
    );
  }
}
