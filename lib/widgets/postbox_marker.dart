import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:postbox_game/monarch_info.dart';
import 'package:postbox_game/theme.dart';

/// Builds a themed [Marker] for a postbox location on a [FlutterMap].
///
/// The marker uses the cipher's display colour from [MonarchInfo.colors] and
/// adds a star badge for rare ciphers or an "H" badge for historic ones.
///
/// [claimed] greys out the marker and adds a gold checkmark overlay.
Marker postboxMarker(
  LatLng point, {
  String? cipher,
  bool claimed = false,
  double size = 40,
  VoidCallback? onTap,
}) {
  final color = claimed
      ? Colors.grey
      : (cipher != null ? MonarchInfo.colors[cipher] : null) ?? postalRed;

  final isRare = cipher != null && MonarchInfo.rareCiphers.contains(cipher);
  final isHistoric =
      cipher != null && MonarchInfo.historicCiphers.contains(cipher);

  return Marker(
    point: point,
    width: size,
    height: size,
    child: GestureDetector(
      onTap: onTap,
      child: _PostboxPin(
        color: color,
        size: size,
        claimed: claimed,
        showStar: isRare && !claimed,
        showHistoric: isHistoric && !claimed,
      ),
    ),
  );
}

/// Builds a [Marker] showing the user's current position.
Marker userPositionMarker(LatLng point) {
  return Marker(
    point: point,
    width: 24,
    height: 24,
    child: Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: postalRed,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(
            color: postalRed.withValues(alpha: 0.3),
            blurRadius: 8,
            spreadRadius: 2,
          ),
        ],
      ),
    ),
  );
}

class _PostboxPin extends StatelessWidget {
  const _PostboxPin({
    required this.color,
    required this.size,
    required this.claimed,
    required this.showStar,
    required this.showHistoric,
  });

  final Color color;
  final double size;
  final bool claimed;
  final bool showStar;
  final bool showHistoric;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Pin body
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: color.withValues(alpha: claimed ? 0.4 : 1.0),
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white,
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(
            Icons.mail_outline,
            color: Colors.white.withValues(alpha: claimed ? 0.6 : 1.0),
            size: size * 0.5,
          ),
        ),
        // Claimed checkmark
        if (claimed)
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(
                color: postalGold,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.check,
                size: size * 0.3,
                color: Colors.white,
              ),
            ),
          ),
        // Rare star badge
        if (showStar)
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(
                color: postalGold,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.star,
                size: size * 0.3,
                color: Colors.white,
              ),
            ),
          ),
        // Historic badge
        if (showHistoric)
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: Colors.brown.shade400,
                shape: BoxShape.circle,
              ),
              child: Text(
                'H',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: size * 0.22,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
