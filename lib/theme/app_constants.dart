import 'package:flutter/material.dart';

/// Design tokens: Colors, Spacings, Radius, Shadows, and Durations.
/// Screens and widgets must reference these tokens and never hardcode raw numbers or colors.
class AppColors {
  AppColors._();

  // Patient palette, for const contexts only. Role-aware widgets must use
  // Theme.of(context).colorScheme (see RolePalette in app_theme.dart).
  static const Color primary = Color(0xFF0273B6);
  static const Color primaryDark = Color(0xFF01579B);
  static const Color primaryLight = Color(0xFFB3E5FC);
  static const Color primaryTint = Color(0xFFE1F5FE); // Nav bg, chip bg, soft fills

  // Surfaces & Backgrounds
  static const Color background = Color(0xFFF5F6FA);
  static const Color surface = Color(0xFFFFFFFF);

  // Typography
  static const Color textPrimary = Color(0xFF1B1F3B);
  static const Color textSecondary = Color(0xFF6B7280);
  static const Color textTertiary = Color(0xFF9CA3AF);
  static const Color textNav = Color(0xFF4B5563); // >= 4.5:1 on every role tint

  // Border & Outlines
  static const Color border = Color(0xFF0273B6);
  static const Color borderSubtle = Color(0xFFE5E7EB);

  // Status & Accents
  static const Color star = Color(0xFFFFB300);
  static const Color success = Color(0xFF2E7D32);
  static const Color error = Color(0xFFD32F2F);
  static const Color locationRed = Color(0xFFE57373);
}

class AppConstants {
  AppConstants._();

  // Spacing
  static const double screenPadding = 16.0;
  static const double sectionGap = 20.0;
  static const double cardGap = 12.0;
  static const double itemGap = 8.0;

  // Border Radii
  static const double radiusHeader = 28.0;
  static const double radiusHero = 24.0;
  static const double radiusNav = 24.0;
  static const double radiusChip = 20.0;
  static const double radiusCard = 16.0;
  static const double radiusSearch = 14.0;
  static const double radiusButton = 12.0;
  static const double radiusInput = 12.0;

  // Standard Shadows
  static const List<BoxShadow> softShadow = [
    BoxShadow(
      color: Color(0x0F000000), // Black at 6% opacity
      blurRadius: 12.0,
      offset: Offset(0, 4),
    ),
  ];

  static const List<BoxShadow> elevatedShadow = [
    BoxShadow(
      color: Color(0x14000000), // Black at 8% opacity
      blurRadius: 16.0,
      offset: Offset(0, 6),
    ),
  ];
}
