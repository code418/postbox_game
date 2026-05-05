import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// Brand colour tokens (recognisable identity — not always AAA as foreground).
const Color postalRed = Color(0xFFC8102E);
const Color postalGold = Color(0xFFFFB400);
const Color royalNavy = Color(0xFF0A1931);
const Color parchment = Color(0xFFFFF8F0);

/// Semantic colour tokens engineered for WCAG AAA contrast in their intended
/// pairings. Prefer these over raw `Colors.grey.*` or brand constants for any
/// text or icon foreground.
class AppColors {
  // Brand surface: button / AppBar background. White-on-this ≈ 8.0:1 (AAA).
  static const Color brandSurface = Color(0xFFA30A24);

  // Brand text/icon on light surfaces. ≈ 9.7:1 on #FFFFFF.
  static const Color brandTextLight = Color(0xFF8B0A20);
  // Brand text/icon on dark surfaces. ≈ 7.5:1 on #1C1C1E.
  static const Color brandTextDark = Color(0xFFFF8A95);

  // Muted/secondary text.
  static const Color mutedTextLight = Color(0xFF595959); // 7.0:1 on white
  static const Color mutedTextDark = Color(0xFFB3B3B3);  // 8.1:1 on #1C1C1E

  // Decorative borders/dividers (non-text → ≥3:1 is enough).
  static const Color borderLight = Color(0xFFB0B0B0);
  static const Color borderDark = Color(0xFF5A5A5A);

  // Status colours (AAA on respective surfaces).
  static const Color successTextLight = Color(0xFF1B5E20); // 7.9:1
  static const Color successTextDark = Color(0xFF7BD389);  // 9.3:1
  static const Color warningTextLight = Color(0xFF7A4100); // 8.1:1
  static const Color warningTextDark = Color(0xFFFFB870);  // 10.0:1
  static const Color errorTextLight = Color(0xFF9E0014);   // 8.5:1
  static const Color errorTextDark = Color(0xFFFF8A95);    // 7.5:1
}

// Spacing scale
class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}

/// Bottom clearance to use on empty/error states so that [Center] widgets
/// appear visually centred in the visible viewport rather than behind the
/// JamesStrip overlay (~72 px). Applied as [EdgeInsets.only(bottom: ...)].
const double kJamesStripClearance = 80.0;

class AppTheme {
  static ThemeData get light {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: postalRed,
        primary: AppColors.brandSurface,
        onPrimary: Colors.white,
        secondary: postalGold,
        onSecondary: Colors.black,
        surface: Colors.white,
        onSurface: const Color(0xFF1A1A1A),
        onSurfaceVariant: AppColors.mutedTextLight,
        outline: AppColors.borderLight,
        error: AppColors.errorTextLight,
        onError: Colors.white,
      ),
    );

    return base.copyWith(
      textTheme: GoogleFonts.plusJakartaSansTextTheme(base.textTheme),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.brandSurface,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.plusJakartaSans(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actionsIconTheme: const IconThemeData(color: Colors.white),
      ),
      cardTheme: CardThemeData(
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm - 2,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.brandSurface,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: GoogleFonts.plusJakartaSans(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: GoogleFonts.plusJakartaSans(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.brandTextLight,
          side: const BorderSide(color: AppColors.brandTextLight),
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: GoogleFonts.plusJakartaSans(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.brandTextLight,
          textStyle: GoogleFonts.plusJakartaSans(
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.borderLight),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.brandTextLight, width: 2),
        ),
        filled: true,
        fillColor: const Color(0xFFF5F5F5),
        prefixIconColor: AppColors.brandTextLight,
        labelStyle: const TextStyle(color: AppColors.mutedTextLight),
      ),
      tabBarTheme: const TabBarThemeData(
        indicatorColor: AppColors.brandTextLight,
        labelColor: AppColors.brandTextLight,
        unselectedLabelColor: AppColors.mutedTextLight,
        dividerColor: Colors.transparent,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: const Color(0xFFFCE4E7),
        labelStyle: GoogleFonts.plusJakartaSans(
            color: AppColors.brandTextLight, fontSize: 12),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: AppColors.brandTextLight.withValues(alpha: 0.18),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: AppColors.brandTextLight);
          }
          return const IconThemeData(color: AppColors.mutedTextLight);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return GoogleFonts.plusJakartaSans(
              color: AppColors.brandTextLight,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            );
          }
          return GoogleFonts.plusJakartaSans(
            color: AppColors.mutedTextLight,
            fontSize: 12,
          );
        }),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.borderLight,
        thickness: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  static ThemeData get dark {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: postalRed,
        brightness: Brightness.dark,
        primary: AppColors.brandSurface,
        onPrimary: Colors.white,
        secondary: postalGold,
        onSecondary: Colors.black,
        surface: const Color(0xFF1C1C1E),
        onSurface: Colors.white,
        onSurfaceVariant: AppColors.mutedTextDark,
        outline: AppColors.borderDark,
        error: AppColors.errorTextDark,
      ),
    );

    const darkRed = AppColors.brandTextDark;
    return base.copyWith(
      textTheme: GoogleFonts.plusJakartaSansTextTheme(base.textTheme),
      appBarTheme: AppBarTheme(
        backgroundColor: const Color(0xFF1C1C1E),
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.plusJakartaSans(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actionsIconTheme: const IconThemeData(color: Colors.white),
      ),
      cardTheme: CardThemeData(
        elevation: 2,
        color: const Color(0xFF2C2C2E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm - 2,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.brandSurface,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: GoogleFonts.plusJakartaSans(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: darkRed,
          side: const BorderSide(color: darkRed),
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: GoogleFonts.plusJakartaSans(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: darkRed,
          textStyle: GoogleFonts.plusJakartaSans(
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.borderDark),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: darkRed, width: 2),
        ),
        filled: true,
        fillColor: const Color(0xFF2C2C2E),
        prefixIconColor: darkRed,
        labelStyle: const TextStyle(color: AppColors.mutedTextDark),
      ),
      tabBarTheme: const TabBarThemeData(
        indicatorColor: darkRed,
        labelColor: darkRed,
        unselectedLabelColor: AppColors.mutedTextDark,
        dividerColor: Colors.transparent,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: const Color(0xFF3A2025),
        labelStyle: GoogleFonts.plusJakartaSans(color: darkRed, fontSize: 12),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xFF1C1C1E),
        indicatorColor: darkRed.withValues(alpha: 0.2),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: darkRed);
          }
          return const IconThemeData(color: AppColors.mutedTextDark);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return GoogleFonts.plusJakartaSans(
              color: darkRed,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            );
          }
          return GoogleFonts.plusJakartaSans(
            color: AppColors.mutedTextDark,
            fontSize: 12,
          );
        }),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.borderDark,
        thickness: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        backgroundColor: const Color(0xFF2C2C2E),
        contentTextStyle: GoogleFonts.plusJakartaSans(color: Colors.white),
      ),
    );
  }
}
