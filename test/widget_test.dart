import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/theme.dart';

void main() {
  group('AppSpacing', () {
    test('spacing scale is strictly increasing', () {
      expect(AppSpacing.xs, lessThan(AppSpacing.sm));
      expect(AppSpacing.sm, lessThan(AppSpacing.md));
      expect(AppSpacing.md, lessThan(AppSpacing.lg));
      expect(AppSpacing.lg, lessThan(AppSpacing.xl));
      expect(AppSpacing.xl, lessThan(AppSpacing.xxl));
    });

    test('xs is positive', () {
      expect(AppSpacing.xs, greaterThan(0));
    });
  });
}
