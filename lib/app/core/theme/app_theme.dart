import 'package:flutter/material.dart';

/// Additional semantic surfaces shared by the player and its dialogs.
@immutable
class HanMusicColors extends ThemeExtension<HanMusicColors> {
  const HanMusicColors({
    required this.muted,
    required this.selectedSurface,
    required this.subtleSurface,
    required this.coverSurface,
    required this.border,
    required this.warningSurface,
    required this.onWarning,
    required this.warningBorder,
  });

  static const light = HanMusicColors(
    muted: Color(0xFF5E6E63),
    selectedSurface: Color(0xFFE7F0E2),
    subtleSurface: Color(0xFFF0F3EC),
    coverSurface: Color(0xFFE0EAD6),
    border: Color(0xFFD5E1D7),
    warningSurface: Color(0xFFFFF0E9),
    onWarning: Color(0xFF7D4835),
    warningBorder: Color(0xFFF1D9CB),
  );

  static const dark = HanMusicColors(
    muted: Color(0xFFB8C6BB),
    selectedSurface: Color(0xFF2A4031),
    subtleSurface: Color(0xFF202C23),
    coverSurface: Color(0xFF304934),
    border: Color(0xFF49594D),
    warningSurface: Color(0xFF40271D),
    onWarning: Color(0xFFF6C8B6),
    warningBorder: Color(0xFF855D48),
  );

  static HanMusicColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<HanMusicColors>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  final Color muted;
  final Color selectedSurface;
  final Color subtleSurface;
  final Color coverSurface;
  final Color border;
  final Color warningSurface;
  final Color onWarning;
  final Color warningBorder;

  @override
  HanMusicColors copyWith({
    Color? muted,
    Color? selectedSurface,
    Color? subtleSurface,
    Color? coverSurface,
    Color? border,
    Color? warningSurface,
    Color? onWarning,
    Color? warningBorder,
  }) => HanMusicColors(
    muted: muted ?? this.muted,
    selectedSurface: selectedSurface ?? this.selectedSurface,
    subtleSurface: subtleSurface ?? this.subtleSurface,
    coverSurface: coverSurface ?? this.coverSurface,
    border: border ?? this.border,
    warningSurface: warningSurface ?? this.warningSurface,
    onWarning: onWarning ?? this.onWarning,
    warningBorder: warningBorder ?? this.warningBorder,
  );

  @override
  HanMusicColors lerp(covariant HanMusicColors? other, double t) {
    if (other == null) return this;
    return HanMusicColors(
      muted: Color.lerp(muted, other.muted, t)!,
      selectedSurface: Color.lerp(selectedSurface, other.selectedSurface, t)!,
      subtleSurface: Color.lerp(subtleSurface, other.subtleSurface, t)!,
      coverSurface: Color.lerp(coverSurface, other.coverSurface, t)!,
      border: Color.lerp(border, other.border, t)!,
      warningSurface: Color.lerp(warningSurface, other.warningSurface, t)!,
      onWarning: Color.lerp(onWarning, other.onWarning, t)!,
      warningBorder: Color.lerp(warningBorder, other.warningBorder, t)!,
    );
  }
}

class HanMusicTheme {
  HanMusicTheme._();

  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final colors = isDark ? HanMusicColors.dark : HanMusicColors.light;
    final primary = isDark ? const Color(0xFFA2D8AF) : const Color(0xFF256747);
    final surface = isDark ? const Color(0xFF161E19) : const Color(0xFFFCFDFB);
    final background = isDark
        ? const Color(0xFF101712)
        : const Color(0xFFF5F7F3);
    final onSurface = isDark
        ? const Color(0xFFDFE8DF)
        : const Color(0xFF24342C);
    final scheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF256747),
          brightness: brightness,
          surface: surface,
        ).copyWith(
          primary: primary,
          onPrimary: isDark ? const Color(0xFF07371D) : Colors.white,
          onSurface: onSurface,
          onSurfaceVariant: colors.muted,
          outline: isDark ? const Color(0xFF899C8E) : const Color(0xFF6F8174),
          outlineVariant: colors.border,
        );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      // Keep Latin and Han text in the same Windows UI family.
      fontFamily: 'Microsoft YaHei UI',
      fontFamilyFallback: const ['Microsoft YaHei', 'DengXian'],
      colorScheme: scheme,
      extensions: [colors],
      scaffoldBackgroundColor: background,
      textTheme: const TextTheme(
        headlineLarge: TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
        headlineMedium: TextStyle(fontSize: 27, fontWeight: FontWeight.w700),
        titleLarge: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(fontSize: 15, height: 1.55),
        bodyMedium: TextStyle(fontSize: 14, height: 1.5),
        bodySmall: TextStyle(fontSize: 12, height: 1.5),
      ).apply(bodyColor: onSurface, displayColor: onSurface),
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
          side: BorderSide(color: colors.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: background,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.border),
        ),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 4,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 15),
        activeTrackColor: primary,
        inactiveTrackColor: isDark ? colors.border : const Color(0xFFDFE6DE),
        thumbColor: primary,
      ),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 450),
      ),
      dividerColor: isDark ? colors.border : const Color(0xFFE5EAE3),
    );
  }
}
