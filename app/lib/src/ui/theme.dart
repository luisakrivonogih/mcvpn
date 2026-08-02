import 'package:flutter/material.dart';

/// The mcvpn design language: a calm, modern take that nods to Minecraft's
/// signature green without the blocky cliché — deep ink backgrounds, a mint /
/// emerald accent, soft glassy surfaces and generous rounding.
class AppColors {
  static const accent = Color(0xFF3DDC84); // mint/emerald
  static const accentAlt = Color(0xFF2BB673);
  static const accentGlow = Color(0xFF4EF0A0);

  static const inkDark = Color(0xFF0B0F14);
  static const surfaceDark = Color(0xFF141A22);
  static const surfaceDark2 = Color(0xFF1C2530);
  static const cardDark = Color(0xFF161D26);

  static const danger = Color(0xFFFF5C7A);
  static const warn = Color(0xFFFFC24B);

  static const gradientA = Color(0xFF3DDC84);
  static const gradientB = Color(0xFF1FA2A6);
}

class AppTheme {
  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      primary: AppColors.accent,
      onPrimary: Color(0xFF06231A),
      secondary: AppColors.gradientB,
      surface: AppColors.surfaceDark,
      onSurface: Color(0xFFE7EEF5),
      error: AppColors.danger,
    );
    return _base(scheme, Brightness.dark).copyWith(
      scaffoldBackgroundColor: AppColors.inkDark,
      cardColor: AppColors.cardDark,
    );
  }

  static ThemeData light() {
    const scheme = ColorScheme.light(
      primary: AppColors.accentAlt,
      onPrimary: Colors.white,
      secondary: AppColors.gradientB,
      surface: Colors.white,
      onSurface: Color(0xFF10151B),
      error: AppColors.danger,
    );
    return _base(scheme, Brightness.light).copyWith(
      scaffoldBackgroundColor: const Color(0xFFF3F6F9),
    );
  }

  static ThemeData _base(ColorScheme scheme, Brightness brightness) {
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: null,
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: brightness == Brightness.dark
            ? AppColors.surfaceDark2
            : const Color(0xFFEDF1F5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.onSurface.withValues(alpha: 0.08),
        thickness: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }
}

/// A reusable glassy card surface.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Gradient? gradient;
  final Color? border;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.onTap,
    this.gradient,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          decoration: BoxDecoration(
            gradient: gradient,
            color: gradient == null
                ? (isDark ? AppColors.cardDark : Colors.white)
                : null,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: border ??
                  (isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.black.withValues(alpha: 0.05)),
            ),
            boxShadow: [
              if (!isDark)
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
            ],
          ),
          padding: padding,
          child: child,
        ),
      ),
    );
  }
}
