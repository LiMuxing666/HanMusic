import 'package:flutter/material.dart';

class HanMusicTheme {
  HanMusicTheme._();

  static ThemeData get light {
    const primary = Color(0xFF256747);
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.light,
      surface: const Color(0xFFFCFDFB),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme.copyWith(primary: primary),
      scaffoldBackgroundColor: const Color(0xFFF5F7F3),
      textTheme:
          const TextTheme(
            headlineLarge: TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
            headlineMedium: TextStyle(
              fontSize: 27,
              fontWeight: FontWeight.w700,
            ),
            titleLarge: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
            titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            bodyLarge: TextStyle(fontSize: 15, height: 1.55),
            bodyMedium: TextStyle(fontSize: 14, height: 1.5),
            bodySmall: TextStyle(fontSize: 12, height: 1.5),
          ).apply(
            bodyColor: const Color(0xFF24342C),
            displayColor: const Color(0xFF24342C),
          ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(44, 46),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(13),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(44, 44),
          side: const BorderSide(color: Color(0xFFD5E1D7)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF5F7F3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFD5E1D7)),
        ),
      ),
      sliderTheme: const SliderThemeData(
        trackHeight: 4,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: RoundSliderOverlayShape(overlayRadius: 15),
        activeTrackColor: primary,
        inactiveTrackColor: Color(0xFFDFE6DE),
        thumbColor: primary,
      ),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 450),
      ),
      dividerColor: const Color(0xFFE5EAE3),
    );
  }
}
