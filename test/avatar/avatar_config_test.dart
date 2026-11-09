import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/avatar/avatar_config.dart';
import 'package:postbox_game/avatar/avatar_svg.dart';

void main() {
  group('AvatarConfig', () {
    test('defaultPostie populates every slot with an in-range index', () {
      final cfg = AvatarConfig.defaultPostie();
      for (final slot in AvatarSlot.values) {
        expect(cfg[slot], inInclusiveRange(0, slot.length() - 1));
      }
    });

    test('toMap and tryFromMap round-trip', () {
      final original = AvatarConfig.defaultPostie();
      final restored = AvatarConfig.tryFromMap(original.toMap());
      expect(restored, equals(original));
    });

    test('tryFromMap returns null for missing or non-map input', () {
      expect(AvatarConfig.tryFromMap(null), isNull);
      expect(AvatarConfig.tryFromMap('not a map'), isNull);
    });

    test('tryFromMap clamps out-of-range indices', () {
      final cfg = AvatarConfig.tryFromMap({'skin': 999});
      expect(cfg, isNotNull);
      expect(cfg![AvatarSlot.skin], lessThan(AvatarSlot.skin.length()));
    });

    test('cycle wraps in both directions', () {
      final cfg = AvatarConfig.defaultPostie();
      final len = AvatarSlot.skin.length();
      final start = cfg[AvatarSlot.skin];
      expect(cfg.cycle(AvatarSlot.skin, 1)[AvatarSlot.skin],
          equals((start + 1) % len));
      expect(cfg.cycle(AvatarSlot.skin, -1)[AvatarSlot.skin],
          equals((start - 1 + len) % len));
    });

    test('random produces in-range indices for every slot', () {
      final cfg = AvatarConfig.random();
      for (final slot in AvatarSlot.values) {
        expect(cfg[slot], inInclusiveRange(0, slot.length() - 1));
      }
    });
  });

  group('buildAvatarSvg', () {
    test('produces a non-empty SVG string for the default postie', () {
      final svg = buildAvatarSvg(AvatarConfig.defaultPostie());
      expect(svg, contains('<svg'));
      expect(svg, contains('viewBox="0 0 200 200"'));
      expect(svg, contains('</svg>'));
    });

    test('renders without crashing for every option in every slot', () {
      // Smoke-test: cycle each slot through its full range and confirm the
      // builder produces a valid <svg>...</svg> envelope each time. Catches
      // accidental string interpolation breakage when a part is added.
      for (final slot in AvatarSlot.values) {
        for (var i = 0; i < slot.length(); i++) {
          final cfg = AvatarConfig.defaultPostie().copyWith(slot, i);
          final svg = buildAvatarSvg(cfg);
          expect(svg.startsWith('\n<svg') || svg.contains('<svg'), isTrue,
              reason: 'slot=$slot index=$i');
          expect(svg, contains('</svg>'));
        }
      }
    });
  });
}
