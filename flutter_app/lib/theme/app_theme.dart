import 'package:flutter/material.dart';

class AppTheme {
  // HSL Colors matching Tailwind CSS theme
  static const Color primary = Color(0xFF0F172A); // hsl(222.2, 47.4%, 11.2%)
  static const Color primaryForeground = Color(0xFFF9FAFB); // hsl(210, 40%, 98%)
  static const Color secondary = Color(0xFFF3F4F6); // hsl(210, 40%, 96.1%)
  static const Color secondaryForeground = Color(0xFF0F172A);
  static const Color background = Color(0xFFFFFFFF);
  static const Color foreground = Color(0xFF0A0F1C); // hsl(222.2, 84%, 4.9%)
  static const Color card = Color(0xFFFFFFFF);
  static const Color cardForeground = Color(0xFF0A0F1C);
  static const Color muted = Color(0xFFF3F4F6);
  static const Color mutedForeground = Color(0xFF64748B); // hsl(215.4, 16.3%, 46.9%)
  static const Color accent = Color(0xFFF3F4F6);
  static const Color accentForeground = Color(0xFF0F172A);
  static const Color destructive = Color(0xFFEF4444); // hsl(0, 84.2%, 60.2%)
  static const Color destructiveForeground = Color(0xFFF9FAFB);
  static const Color border = Color(0xFFE2E8F0); // hsl(214.3, 31.8%, 91.4%)
  static const Color input = Color(0xFFE2E8F0);
  static const Color ring = Color(0xFF0A0F1C);

  // Congestion colors
  static const Color congestionLow = Color(0xFFD1FAE5); // hsl(142, 76%, 96%)
  static const Color congestionMedium = Color(0xFFFEF3C7); // hsl(49, 96%, 92%)
  static const Color congestionHigh = Color(0xFFFEE2E2); // hsl(0, 84%, 90%)
  static const Color congestionCritical = Color(0xFFFECACA); // hsl(0, 74%, 82%)

  // Dark mode colors
  static const Color darkBackground = Color(0xFF0A0F1C);
  static const Color darkForeground = Color(0xFFF9FAFB);
  static const Color darkCard = Color(0xFF0A0F1C);
  static const Color darkCardForeground = Color(0xFFF9FAFB);
  static const Color darkMuted = Color(0xFF1E293B); // hsl(217.2, 32.6%, 17.5%)
  static const Color darkMutedForeground = Color(0xFF94A3B8); // hsl(215, 20.2%, 65.1%)
  static const Color darkBorder = Color(0xFF1E293B);

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.light(
        primary: primary,
        onPrimary: primaryForeground,
        secondary: secondary,
        onSecondary: secondaryForeground,
        surface: card,
        onSurface: cardForeground,
        error: destructive,
        onError: destructiveForeground,
      ),
      scaffoldBackgroundColor: background,
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: border, width: 1),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: input),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: input),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: ring, width: 2),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: primaryForeground,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: foreground,
        elevation: 0,
        centerTitle: false,
      ),
      dividerColor: border,
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.dark(
        primary: primaryForeground,
        onPrimary: primary,
        secondary: darkMuted,
        onSecondary: primaryForeground,
        surface: darkCard,
        onSurface: darkCardForeground,
        error: destructive,
        onError: destructiveForeground,
      ),
      scaffoldBackgroundColor: darkBackground,
      cardTheme: CardThemeData(
        color: darkCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: darkBorder, width: 1),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: darkBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: darkBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: ring, width: 2),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: darkBackground,
        foregroundColor: darkForeground,
        elevation: 0,
        centerTitle: false,
      ),
      dividerColor: darkBorder,
    );
  }

  // Helper methods for congestion colors
  static Color getCongestionColor(String level) {
    switch (level.toLowerCase()) {
      case 'low':
        return congestionLow;
      case 'medium':
        return congestionMedium;
      case 'high':
        return congestionHigh;
      case 'critical':
        return congestionCritical;
      default:
        return muted;
    }
  }
}
