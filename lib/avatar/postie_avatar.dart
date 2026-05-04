import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme.dart';
import 'avatar_config.dart';
import 'avatar_svg.dart';

/// A circular avatar built from an [AvatarConfig].
///
/// When [config] is null falls back to [InitialsAvatar] so users who haven't
/// built a postie yet still get a recognisable circle (initials on red).
class PostieAvatar extends StatelessWidget {
  final AvatarConfig? config;
  final double size;
  final String? fallbackName;

  const PostieAvatar({
    super.key,
    required this.config,
    required this.size,
    this.fallbackName,
  });

  @override
  Widget build(BuildContext context) {
    final cfg = config;
    if (cfg == null) {
      return InitialsAvatar(name: fallbackName ?? '', size: size);
    }
    return SizedBox(
      width: size,
      height: size,
      child: SvgPicture.string(
        buildAvatarSvg(cfg),
        width: size,
        height: size,
      ),
    );
  }
}

/// Coloured circle with up-to-2-letter initials. Default fallback when a user
/// hasn't customised an avatar.
class InitialsAvatar extends StatelessWidget {
  final String name;
  final double size;
  final Color? backgroundColor;

  const InitialsAvatar({
    super.key,
    required this.name,
    required this.size,
    this.backgroundColor,
  });

  static String initialsFor(String name) {
    final t = name.trim();
    if (t.isEmpty) return '?';
    final parts = t.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return t.substring(0, t.length.clamp(0, 2)).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: backgroundColor ?? postalRed,
      child: Text(
        initialsFor(name),
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: size * 0.36,
        ),
      ),
    );
  }
}
