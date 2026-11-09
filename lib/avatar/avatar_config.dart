import 'dart:math';

import 'avatar_parts.dart';

/// One slot the user can pick from in the avatar creator.
enum AvatarSlot {
  background('bg', 'Background'),
  skin('skin', 'Skin Tone'),
  head('head', 'Head Shape'),
  hair('hair', 'Hair Style'),
  hairColor('hairColor', 'Hair Colour'),
  eyes('eyes', 'Eyes'),
  nose('nose', 'Nose'),
  facial('facial', 'Facial Hair'),
  glasses('glasses', 'Glasses'),
  hat('hat', 'Hat');

  final String key;
  final String label;
  const AvatarSlot(this.key, this.label);

  int length() => switch (this) {
        AvatarSlot.background => avatarBackgrounds.length,
        AvatarSlot.skin => avatarSkin.length,
        AvatarSlot.head => avatarHeads.length,
        AvatarSlot.hair => avatarHair.length,
        AvatarSlot.hairColor => avatarHairColors.length,
        AvatarSlot.eyes => avatarEyes.length,
        AvatarSlot.nose => avatarNoses.length,
        AvatarSlot.facial => avatarFacial.length,
        AvatarSlot.glasses => avatarGlasses.length,
        AvatarSlot.hat => avatarHats.length,
      };

  String optionName(int index) {
    final i = index.clamp(0, length() - 1);
    return switch (this) {
      AvatarSlot.background => avatarBackgrounds[i].name,
      AvatarSlot.skin => avatarSkin[i].name,
      AvatarSlot.head => avatarHeads[i].name,
      AvatarSlot.hair => avatarHair[i].name,
      AvatarSlot.hairColor => avatarHairColors[i].name,
      AvatarSlot.eyes => avatarEyes[i].name,
      AvatarSlot.nose => avatarNoses[i].name,
      AvatarSlot.facial => avatarFacial[i].name,
      AvatarSlot.glasses => avatarGlasses[i].name,
      AvatarSlot.hat => avatarHats[i].name,
    };
  }

  /// Hex string for slot options that have a swatch (skin, hair, bg).
  String? swatchColor(int index) {
    final i = index.clamp(0, length() - 1);
    return switch (this) {
      AvatarSlot.background => avatarBackgrounds[i].fill,
      AvatarSlot.skin => avatarSkin[i].fill,
      AvatarSlot.hairColor => avatarHairColors[i].fill,
      _ => null,
    };
  }
}

/// User's avatar configuration — a small map of slot indices.
class AvatarConfig {
  final Map<AvatarSlot, int> indices;

  const AvatarConfig._(this.indices);

  factory AvatarConfig.fromIndices(Map<AvatarSlot, int> indices) {
    final clamped = <AvatarSlot, int>{};
    for (final slot in AvatarSlot.values) {
      final raw = indices[slot] ?? 0;
      clamped[slot] = raw.clamp(0, slot.length() - 1);
    }
    return AvatarConfig._(clamped);
  }

  /// Default Postman James-ish avatar: peach skin, side-parting hair, brown
  /// hair, happy eyes, button nose, postman cap, navy background.
  factory AvatarConfig.defaultPostie() => AvatarConfig.fromIndices({
        AvatarSlot.background: 1, // navy
        AvatarSlot.skin: 1, // peach
        AvatarSlot.head: 0, // oval
        AvatarSlot.hair: 2, // side parting
        AvatarSlot.hairColor: 1, // brown
        AvatarSlot.eyes: 2, // happy
        AvatarSlot.nose: 0, // button
        AvatarSlot.facial: 0, // clean shaven
        AvatarSlot.glasses: 0, // none
        AvatarSlot.hat: 1, // postman cap
      });

  factory AvatarConfig.random([Random? rng]) {
    final r = rng ?? Random();
    return AvatarConfig.fromIndices({
      for (final slot in AvatarSlot.values)
        slot: slot == AvatarSlot.hat
            // Hats appear roughly half the time so randomise doesn't always crown the user.
            ? (r.nextDouble() < 0.5 ? 0 : r.nextInt(slot.length()))
            : r.nextInt(slot.length()),
    });
  }

  /// Parse from Firestore `users/{uid}.avatar` map. Returns null for missing /
  /// unrecognised structure so the caller can fall back to the initials avatar.
  static AvatarConfig? tryFromMap(Object? raw) {
    if (raw is! Map) return null;
    final indices = <AvatarSlot, int>{};
    for (final slot in AvatarSlot.values) {
      final v = raw[slot.key];
      if (v is num) indices[slot] = v.toInt();
    }
    if (indices.isEmpty) return null;
    return AvatarConfig.fromIndices(indices);
  }

  Map<String, int> toMap() =>
      {for (final slot in AvatarSlot.values) slot.key: indices[slot] ?? 0};

  int operator [](AvatarSlot slot) => indices[slot] ?? 0;

  AvatarConfig copyWith(AvatarSlot slot, int value) {
    final next = Map<AvatarSlot, int>.from(indices);
    next[slot] = value.clamp(0, slot.length() - 1);
    return AvatarConfig._(next);
  }

  AvatarConfig cycle(AvatarSlot slot, int direction) {
    final len = slot.length();
    final cur = this[slot];
    final next = (cur + direction + len) % len;
    return copyWith(slot, next);
  }

  @override
  bool operator ==(Object other) {
    if (other is! AvatarConfig) return false;
    for (final slot in AvatarSlot.values) {
      if (other[slot] != this[slot]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll([
        for (final slot in AvatarSlot.values) indices[slot] ?? 0,
      ]);
}
