import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/user_role.dart';
import 'app_constants.dart';

/// Colours for one role portal. Every role colour in the app comes from
/// [RolePalette.of]; screens read them through `Theme.of(context).colorScheme`.
///
/// `primary` is chosen so white text on it passes WCAG AA (>= 4.5:1).
class RolePalette {
  final String name;
  final Color primary;
  final Color primaryDark;
  final Color tint;

  const RolePalette({
    required this.name,
    required this.primary,
    required this.primaryDark,
    required this.tint,
  });

  static const patient = RolePalette(
    name: 'Patient',
    primary: Color(0xFF0273B6), // Blue, 5.1:1 with white, 4.7:1 on background
    primaryDark: Color(0xFF01579B),
    tint: Color(0xFFE1F5FE),
  );
  static const doctor = RolePalette(
    name: 'Doctor',
    primary: Color(0xFF15803D), // Green, 5.0:1 with white
    primaryDark: Color(0xFF166534),
    tint: Color(0xFFDCFCE7),
  );
  static const operator = RolePalette(
    name: 'Operator',
    primary: Color(0xFFC2410C), // Orange, 5.2:1 with white
    primaryDark: Color(0xFF9A3412),
    tint: Color(0xFFFFEDD5),
  );
  static const admin = RolePalette(
    name: 'Admin',
    primary: Color(0xFF581C87), // Purple, 10.9:1 with white
    primaryDark: Color(0xFF3B0764),
    tint: Color(0xFFF3E8FF),
  );

  static RolePalette of(UserRole role) => switch (role) {
        UserRole.patient => patient,
        UserRole.doctor => doctor,
        UserRole.operator => operator,
        UserRole.admin => admin,
      };
}

/// The role whose theme the whole app (including dialogs, bottom sheets and
/// pushed routes) is drawn in. MainShell updates it on role switch.
class RoleThemeController {
  RoleThemeController._();

  static final ValueNotifier<UserRole> activeRole =
      ValueNotifier<UserRole>(UserRole.patient);

  static void setRole(UserRole role) {
    if (activeRole.value != role) activeRole.value = role;
  }
}

/// AppTheme configured with GoogleFonts.poppins typography and strict design tokens.
/// One [ThemeData] per role, built from [RolePalette].
class AppTheme {
  AppTheme._();

  static TextStyle get screenTitle => GoogleFonts.poppins(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      );

  static TextStyle get sectionTitle => GoogleFonts.poppins(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      );

  static TextStyle get cardTitle => GoogleFonts.poppins(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      );

  static TextStyle get body => GoogleFonts.poppins(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: AppColors.textSecondary,
      );

  static TextStyle get bodyBold => GoogleFonts.poppins(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      );

  static TextStyle get caption => GoogleFonts.poppins(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: AppColors.textSecondary,
      );

  static TextStyle get captionSmall => GoogleFonts.poppins(
        fontSize: 11,
        fontWeight: FontWeight.w400,
        color: AppColors.textSecondary,
      );

  static TextStyle get buttonText => GoogleFonts.poppins(
        fontSize: 14,
        fontWeight: FontWeight.w600,
      );

  static final Map<UserRole, ThemeData> _cache = {};

  static ThemeData themeForRole(UserRole role) =>
      _cache.putIfAbsent(role, () => _build(RolePalette.of(role)));

  static ThemeData _build(RolePalette palette) {
    final primary = palette.primary;
    final primaryTint = palette.tint;
    final primaryDark = palette.primaryDark;

    final baseTextTheme = GoogleFonts.poppinsTextTheme();
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppConstants.radiusButton),
    );
    const buttonPadding = EdgeInsets.symmetric(horizontal: 18, vertical: 12);

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      primaryColor: primary,
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: ColorScheme(
        brightness: Brightness.light,
        primary: primary,
        onPrimary: Colors.white,
        primaryContainer: primaryTint,
        onPrimaryContainer: primaryDark,
        secondary: primaryDark,
        onSecondary: Colors.white,
        secondaryContainer: primaryTint,
        onSecondaryContainer: primaryDark,
        surface: AppColors.surface,
        onSurface: AppColors.textPrimary,
        onSurfaceVariant: AppColors.textSecondary,
        surfaceTint: Colors.transparent,
        outline: AppColors.borderSubtle,
        error: AppColors.error,
        onError: Colors.white,
      ),
      textTheme: baseTextTheme.copyWith(
        titleLarge: screenTitle,
        titleMedium: sectionTitle,
        titleSmall: cardTitle,
        bodyMedium: body,
        bodySmall: caption,
        labelLarge: buttonText,
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        shadowColor: Colors.black.withValues(alpha: 0.06),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusCard),
        ),
        margin: EdgeInsets.zero,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: GoogleFonts.poppins(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      tabBarTheme: const TabBarThemeData(
        labelColor: Colors.white,
        unselectedLabelColor: Colors.white70,
        indicatorColor: Colors.white,
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          shape: buttonShape,
          padding: buttonPadding,
          textStyle: buttonText,
          elevation: 0,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          shape: buttonShape,
          padding: buttonPadding,
          textStyle: buttonText,
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          side: BorderSide(color: primary, width: 1.0),
          shape: buttonShape,
          padding: buttonPadding,
          textStyle: buttonText,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          shape: buttonShape,
          textStyle: buttonText,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusCard),
        ),
        extendedTextStyle: buttonText,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusHero),
        ),
        titleTextStyle: sectionTitle.copyWith(fontSize: 18),
        contentTextStyle: body.copyWith(color: AppColors.textPrimary),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppConstants.radiusHero),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.textPrimary,
        contentTextStyle: GoogleFonts.poppins(fontSize: 13, color: Colors.white),
        actionTextColor: primaryTint,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusButton),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: primaryTint,
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusChip),
        ),
        side: BorderSide.none,
        backgroundColor: primaryTint,
        selectedColor: primary,
        checkmarkColor: Colors.white,
        labelStyle: GoogleFonts.poppins(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: AppColors.textPrimary,
        ),
        secondaryLabelStyle: GoogleFonts.poppins(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: primaryTint,
        indicatorColor: primary.withValues(alpha: 0.14),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? primary
                : AppColors.textNav,
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: primary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusButton),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : null,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? primary : null,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.borderSubtle,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        hintStyle: caption,
        labelStyle: caption,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusInput),
          borderSide: const BorderSide(color: AppColors.borderSubtle),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusInput),
          borderSide: const BorderSide(color: AppColors.borderSubtle),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusInput),
          borderSide: BorderSide(color: primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }

  static ThemeData get lightTheme => themeForRole(UserRole.patient);
}

/// Shorthand for the active role's colours inside widgets.
extension RoleColors on BuildContext {
  ColorScheme get colors => Theme.of(this).colorScheme;
  Color get rolePrimary => Theme.of(this).colorScheme.primary;
  Color get roleTint => Theme.of(this).colorScheme.primaryContainer;
  Color get roleDark => Theme.of(this).colorScheme.onPrimaryContainer;
}
