import 'package:flutter/material.dart';

abstract final class KenaiSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
}

abstract final class KenaiRadii {
  static const double control = 10;
  static const double card = 16;
  static const double panel = 24;
}

abstract final class KenaiTheme {
  static const Color accent = Color(0xFF7048F7);
  static const Color success = Color(0xFF43B97F);
  static const Color warning = Color(0xFFE2A94B);
  static const Color danger = Color(0xFFE45D68);

  static ThemeData light() => _build(
        brightness: Brightness.light,
        surface: const Color(0xFFD4E7F5),
        panel: const Color(0xFFE0E8FA),
        foreground: const Color(0xFF101D52),
      );

  static ThemeData dark() => _build(
        brightness: Brightness.dark,
        surface: const Color(0xFF060C1C),
        panel: const Color(0xFF0D162B),
        foreground: const Color(0xFFF6F7FF),
      );

  static ThemeData _build({
    required Brightness brightness,
    required Color surface,
    required Color panel,
    required Color foreground,
  }) {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
      surface: surface,
    );
    final bool dark = brightness == Brightness.dark;
    final Color muted =
        dark ? const Color(0xFF9BAEDB) : const Color(0xFF6577AF);
    final Color line = dark ? const Color(0xFF293C66) : const Color(0xFFC7C8EE);
    final Color primary =
        dark ? const Color(0xFFB7AAFF) : const Color(0xFF7041EF);
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: 'Segoe UI',
      colorScheme: scheme.copyWith(
        primary: primary,
        onPrimary: Colors.white,
        surface: surface,
        onSurface: foreground,
        onSurfaceVariant: muted,
        outline: line,
      ),
      scaffoldBackgroundColor: surface,
      iconTheme: IconThemeData(color: muted),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF6934EF),
          foregroundColor: Colors.white,
          minimumSize: const Size(40, 44),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: foreground,
          backgroundColor: panel.withValues(alpha: .72),
          side: BorderSide(color: line),
          minimumSize: const Size(40, 44),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: panel,
        selectedColor: dark ? const Color(0xFF4320AC) : const Color(0xFF9B6AFF),
        labelStyle:
            TextStyle(fontFamily: 'Segoe UI', color: foreground, fontSize: 14),
        secondaryLabelStyle: const TextStyle(
            fontFamily: 'Segoe UI', color: Colors.white, fontSize: 14),
        side: BorderSide(color: line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      ),
      listTileTheme: ListTileThemeData(iconColor: muted, textColor: foreground),
      cardTheme: CardThemeData(
        color: panel,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KenaiRadii.card),
          side: BorderSide(color: line),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: panel,
        indicatorColor: accent.withValues(alpha: 0.16),
        minWidth: 72,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: panel,
        hintStyle: TextStyle(color: muted),
        prefixIconColor: muted,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: line)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: primary)),
      ),
    );
  }
}
