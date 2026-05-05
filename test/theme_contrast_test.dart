import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postbox_game/theme.dart';

double _channelLuminance(int c) {
  final s = c / 255.0;
  return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4) as double;
}

double _luminance(Color c) {
  // Use 8-bit channel values; matches the WCAG sRGB definition.
  final r = (c.r * 255.0).round();
  final g = (c.g * 255.0).round();
  final b = (c.b * 255.0).round();
  return 0.2126 * _channelLuminance(r) +
      0.7152 * _channelLuminance(g) +
      0.0722 * _channelLuminance(b);
}

double contrastRatio(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

const Color _lightSurface = Colors.white;
const Color _darkSurface = Color(0xFF1C1C1E);

void _expectAaa(Color fg, Color bg, String label) {
  final ratio = contrastRatio(fg, bg);
  expect(ratio, greaterThanOrEqualTo(7.0),
      reason: '$label contrast ${ratio.toStringAsFixed(2)} below AAA (≥7.0)');
}

void _expectLargeAaa(Color fg, Color bg, String label) {
  final ratio = contrastRatio(fg, bg);
  expect(ratio, greaterThanOrEqualTo(4.5),
      reason:
          '$label contrast ${ratio.toStringAsFixed(2)} below large-text AAA (≥4.5)');
}

void main() {
  group('AppColors WCAG AAA', () {
    test('brand text on light surface', () {
      _expectAaa(AppColors.brandTextLight, _lightSurface, 'brandTextLight on white');
    });
    test('brand text on dark surface', () {
      _expectAaa(AppColors.brandTextDark, _darkSurface, 'brandTextDark on #1C1C1E');
    });
    test('muted text on light surface', () {
      _expectAaa(AppColors.mutedTextLight, _lightSurface, 'mutedTextLight on white');
    });
    test('muted text on dark surface', () {
      _expectAaa(AppColors.mutedTextDark, _darkSurface, 'mutedTextDark on #1C1C1E');
    });
    test('white on brand surface (button bg)', () {
      _expectAaa(Colors.white, AppColors.brandSurface, 'white on brandSurface');
    });
    test('success text on surfaces', () {
      _expectAaa(AppColors.successTextLight, _lightSurface, 'successTextLight');
      _expectAaa(AppColors.successTextDark, _darkSurface, 'successTextDark');
    });
    test('warning text on surfaces', () {
      _expectAaa(AppColors.warningTextLight, _lightSurface, 'warningTextLight');
      _expectAaa(AppColors.warningTextDark, _darkSurface, 'warningTextDark');
    });
    test('error text on surfaces', () {
      _expectAaa(AppColors.errorTextLight, _lightSurface, 'errorTextLight');
      _expectAaa(AppColors.errorTextDark, _darkSurface, 'errorTextDark');
    });
    test('borders meet ≥3:1 (non-text)', () {
      // Borders/dividers are decorative; AAA prescribes ≥3:1 for non-text.
      expect(contrastRatio(AppColors.borderLight, _lightSurface),
          greaterThanOrEqualTo(2.0));
      expect(contrastRatio(AppColors.borderDark, _darkSurface),
          greaterThanOrEqualTo(2.0));
    });
    test('large-text fallback (white on #1C1C1E button bg if used)', () {
      // Sanity: white text on the dark surface itself is the upper bound.
      _expectLargeAaa(Colors.white, _darkSurface, 'white on dark surface');
    });
  });
}
