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
  static ThemeData get dark {
    final base = ThemeData(
      useMaterial3: true,
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
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: postalRed,
          textStyle: const TextStyle(
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
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
        titleMedium: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
        titleSmall: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
        bodyMedium: TextStyle(
          fontSize: 12,
          color: Colors.white70,
        ),
        bodySmall: TextStyle(
          fontSize: 10,
          color: Colors.white54,
        ),
        labelLarge: TextStyle(
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
