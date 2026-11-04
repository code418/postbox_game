import 'package:flutter/material.dart';
import 'package:postbox_game/theme.dart';

/// Spacing scale for Wear OS — tighter than phone [AppSpacing] to maximise
/// the usable area on a ~200 dp diameter round screen.
class WearSpacing {
  static const double xs = 2;
  static const double sm = 4;
  static const double md = 8;
  static const double lg = 12;
  static const double xl = 16;
}

/// Watch-optimised Material 3 theme.
///
/// Dark by default (OLED battery savings), with postal-red primary and
/// large touch targets. Uses the system font rather than Google Fonts to
/// avoid network calls and save memory on constrained hardware.
class WearTheme {
  /// Named explicitly rather than left to the platform default, which on
  /// Android resolves to Roboto anyway: with a family name, tests can load
  /// the real face from the Flutter SDK cache and measure text as the watch
  /// renders it (see test/wear_round_fit_test.dart). The unnamed default
  /// measures with the ~2x-wider placeholder test font instead.
  static const String fontFamily = 'Roboto';

  static ThemeData get dark {
    final base = ThemeData(
      useMaterial3: true,
      fontFamily: fontFamily,
      colorScheme: ColorScheme.fromSeed(
        seedColor: postalRed,
        brightness: Brightness.dark,
        primary: postalRed,
        onPrimary: Colors.white,
        secondary: postalGold,
        onSecondary: Colors.black,
        surface: Colors.black,
        onSurface: Colors.white,
        error: const Color(0xFFCF6679),
      ),
    );

    return base.copyWith(
      scaffoldBackgroundColor: Colors.black,
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: postalRed,
          foregroundColor: Colors.white,
          minimumSize: const Size(48, 48),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
            fontFamily: fontFamily,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: postalRed,
          side: const BorderSide(color: postalRed),
          minimumSize: const Size(48, 48),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
            fontFamily: fontFamily,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: postalRed,
          textStyle: const TextStyle(
            fontFamily: fontFamily,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
        ),
      ),
      textTheme: const TextTheme(
        headlineSmall: TextStyle(
          fontFamily: fontFamily,
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
        titleMedium: TextStyle(
          fontFamily: fontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
        titleSmall: TextStyle(
          fontFamily: fontFamily,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
        bodyMedium: TextStyle(
          fontFamily: fontFamily,
          fontSize: 12,
          color: Colors.white70,
        ),
        bodySmall: TextStyle(
          fontFamily: fontFamily,
          fontSize: 10,
          color: Colors.white70,
        ),
        labelLarge: TextStyle(
          fontFamily: fontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }

  /// Ambient mode variant — minimal white-on-black for always-on display.
  static ThemeData get ambient {
    return dark.copyWith(
      colorScheme: dark.colorScheme.copyWith(
        primary: Colors.white,
        onPrimary: Colors.black,
      ),
    );
  }
}
