import 'package:flutter/material.dart';

/// Central place for all app-wide constants, theme, and color palette.
class AppConstants {
  AppConstants._();

  // ── Color palette ──────────────────────────────────────────────────────────
  // Clean, professional IT-tool palette: deep navy + electric blue accent
  // with warm off-white surfaces. Single bold accent, everything else quiet.
  static const Color primaryNavy = Color(0xFF0D1B2A);
  static const Color accentBlue = Color(0xFF1A73E8);
  static const Color accentGreen = Color(0xFF00C48C);
  static const Color accentAmber = Color(0xFFFFA726);
  static const Color accentRed = Color(0xFFE53935);
  static const Color surfaceLight = Color(0xFFF5F7FA);
  static const Color surfaceCard = Color(0xFFFFFFFF);
  static const Color textPrimary = Color(0xFF0D1B2A);
  static const Color textSecondary = Color(0xFF607080);
  static const Color divider = Color(0xFFE0E6EF);

  // ── Typography scale ───────────────────────────────────────────────────────
  static const String fontFamily = 'Roboto';

  // ── Status badge colors ────────────────────────────────────────────────────
  static const Map<String, Color> statusColors = {
    'Ready to Deploy': accentGreen,
    'Deployed': accentBlue,
    'Pending': accentAmber,
    'Archived': textSecondary,
    'Broken / Needs Repair': accentRed,
  };

  static Color statusColor(String? status) =>
      statusColors[status] ?? textSecondary;

  // ── Material Theme ─────────────────────────────────────────────────────────
  static ThemeData get theme => ThemeData(
        useMaterial3: true,
        fontFamily: fontFamily,
        colorScheme: ColorScheme.fromSeed(
          seedColor: accentBlue,
          brightness: Brightness.light,
          surface: surfaceLight,
        ),
        scaffoldBackgroundColor: surfaceLight,
        appBarTheme: const AppBarTheme(
          backgroundColor: primaryNavy,
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            fontFamily: fontFamily,
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Colors.white,
            letterSpacing: 0.2,
          ),
        ),
        cardTheme: CardThemeData(
          color: surfaceCard,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: divider, width: 1),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: accentBlue,
            foregroundColor: Colors.white,
            elevation: 0,
            padding:
                const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
            textStyle: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: accentBlue,
            side: const BorderSide(color: accentBlue),
            padding:
                const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
            textStyle: const TextStyle(
              fontFamily: fontFamily,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surfaceCard,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: divider),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: divider),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: accentBlue, width: 2),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: accentRed),
          ),
          labelStyle: const TextStyle(color: textSecondary),
        ),
        dividerTheme: const DividerThemeData(
          color: divider,
          thickness: 1,
          space: 1,
        ),
        chipTheme: ChipThemeData(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6)),
          side: BorderSide.none,
        ),
      );
}
