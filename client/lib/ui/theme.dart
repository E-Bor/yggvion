import 'package:flutter/material.dart';
import '../domain/models.dart';

abstract final class Palette {
  static const background = Color(0xff111419),
      surface = Color(0xff1a1e25),
      raised = Color(0xff242b35),
      border = Color(0xff303744),
      text = Color(0xffe8ecf2),
      muted = Color(0xff929dad),
      blue = Color(AppSettings.defaultAccentColor),
      pink = Color(0xffdfa6ba),
      green = Color(0xff8ac9b4);
  static const projects = [
    blue,
    Color(0xffb7a6e8),
    Color(0xffd6b780),
    green,
    pink,
    Color(0xff8fc7cf),
    Color(0xffd7a58d),
    Color(0xffa8b3c5),
  ];
  static const projectNames = [
    'Голубой',
    'Лаванда',
    'Песочный',
    'Шалфей',
    'Розовый',
    'Бирюзовый',
    'Терракота',
    'Серый',
  ];

  // Opaque surfaces keep grid lines and overlapping cards from showing through.
  static Color taskSurface(
    Color accent, {
    bool subdued = false,
    bool selected = false,
  }) =>
      AppPalette.dark.taskSurface(accent, subdued: subdued, selected: selected);
}

@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.raised,
    required this.border,
    required this.text,
    required this.muted,
    required this.pink,
    required this.green,
  });

  static const dark = AppPalette(
    brightness: Brightness.dark,
    background: Palette.background,
    surface: Palette.surface,
    raised: Palette.raised,
    border: Palette.border,
    text: Palette.text,
    muted: Palette.muted,
    pink: Palette.pink,
    green: Palette.green,
  );
  static const light = AppPalette(
    brightness: Brightness.light,
    background: Color(0xfff3f5f8),
    surface: Color(0xffffffff),
    raised: Color(0xffe8edf3),
    border: Color(0xffd4dbe6),
    text: Color(0xff202735),
    muted: Color(0xff5d697c),
    pink: Color(0xff9f3f61),
    green: Color(0xff226d57),
  );

  final Brightness brightness;
  final Color background, surface, raised, border, text, muted, pink, green;

  // Retain the chosen hue while giving pastel accents enough contrast on white.
  Color accent(Color color) {
    if (brightness == Brightness.dark) return color;
    var result = color.withValues(alpha: 1);
    while (result.computeLuminance() > .12) {
      result = Color.lerp(result, Colors.black, .08)!;
    }
    return result;
  }

  Color taskSurface(
    Color accent, {
    bool subdued = false,
    bool selected = false,
  }) => Color.lerp(
    surface,
    accent.withValues(alpha: 1),
    brightness == Brightness.light
        ? (subdued
              ? .04
              : selected
              ? .19
              : .11)
        : (subdued
              ? .08
              : selected
              ? .33
              : .26),
  )!;

  @override
  AppPalette copyWith({
    Brightness? brightness,
    Color? background,
    Color? surface,
    Color? raised,
    Color? border,
    Color? text,
    Color? muted,
    Color? pink,
    Color? green,
  }) => AppPalette(
    brightness: brightness ?? this.brightness,
    background: background ?? this.background,
    surface: surface ?? this.surface,
    raised: raised ?? this.raised,
    border: border ?? this.border,
    text: text ?? this.text,
    muted: muted ?? this.muted,
    pink: pink ?? this.pink,
    green: green ?? this.green,
  );

  @override
  AppPalette lerp(covariant AppPalette? other, double t) {
    if (other == null) return this;
    return AppPalette(
      brightness: t < .5 ? brightness : other.brightness,
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      raised: Color.lerp(raised, other.raised, t)!,
      border: Color.lerp(border, other.border, t)!,
      text: Color.lerp(text, other.text, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      pink: Color.lerp(pink, other.pink, t)!,
      green: Color.lerp(green, other.green, t)!,
    );
  }
}

extension AppColors on BuildContext {
  Color get accentColor => Theme.of(this).colorScheme.primary;
  AppPalette get palette =>
      Theme.of(this).extension<AppPalette>() ??
      (Theme.of(this).brightness == Brightness.light
          ? AppPalette.light
          : AppPalette.dark);
}

class ColorPalettePicker extends StatelessWidget {
  const ColorPalettePicker({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final int value;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (var i = 0; i < Palette.projects.length; i++)
        Tooltip(
          message: Palette.projectNames[i],
          child: Semantics(
            label: Palette.projectNames[i],
            selected: value == Palette.projects[i].toARGB32(),
            button: true,
            child: InkWell(
              key: ValueKey('color-choice-$i'),
              borderRadius: BorderRadius.circular(12),
              onTap: () => onChanged(Palette.projects[i].toARGB32()),
              child: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: context.palette.taskSurface(Palette.projects[i]),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: context.palette.accent(Palette.projects[i]),
                    width: value == Palette.projects[i].toARGB32() ? 2 : .7,
                  ),
                ),
                child: Icon(
                  value == Palette.projects[i].toARGB32()
                      ? Icons.check_rounded
                      : Icons.circle,
                  color: context.palette.accent(Palette.projects[i]),
                  size: value == Palette.projects[i].toARGB32() ? 20 : 10,
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

RelativeRect menuPosition(BuildContext context, Offset globalPosition) {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  return RelativeRect.fromRect(
    Rect.fromLTWH(
      overlay.globalToLocal(globalPosition).dx,
      overlay.globalToLocal(globalPosition).dy,
      1,
      1,
    ),
    Offset.zero & overlay.size,
  );
}

ThemeData appTheme({
  int accentColor = AppSettings.defaultAccentColor,
  Brightness brightness = Brightness.dark,
}) {
  final palette = brightness == Brightness.light
      ? AppPalette.light
      : AppPalette.dark;
  final accent = palette.accent(Color(accentColor));
  final scheme =
      ColorScheme.fromSeed(
        seedColor: accent,
        brightness: brightness,
        surface: palette.surface,
      ).copyWith(
        primary: accent,
        onPrimary: brightness == Brightness.light
            ? Colors.white
            : palette.background,
        primaryContainer: palette.taskSurface(accent, selected: true),
        onPrimaryContainer: accent,
        secondary: accent,
        onSecondary: brightness == Brightness.light
            ? Colors.white
            : palette.background,
        secondaryContainer: palette.taskSurface(accent),
        onSecondaryContainer: accent,
        outline: palette.border,
        onSurface: brightness == Brightness.light ? palette.text : null,
        onSurfaceVariant: brightness == Brightness.light ? palette.muted : null,
        surfaceContainerHighest: brightness == Brightness.light
            ? palette.raised
            : null,
        surfaceContainerLow: brightness == Brightness.light
            ? palette.surface
            : null,
        outlineVariant: brightness == Brightness.light ? palette.border : null,
      );
  return ThemeData(
    useMaterial3: true,
    extensions: [palette],
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.background,
    fontFamily: 'Inter',
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: accent,
      selectionColor: accent.withValues(alpha: .28),
      selectionHandleColor: accent,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(4),
      radius: const Radius.circular(4),
      thumbColor: WidgetStatePropertyAll(palette.muted.withValues(alpha: .35)),
    ),
    textTheme: TextTheme(
      headlineLarge: TextStyle(
        fontSize: 30,
        fontWeight: FontWeight.w600,
        letterSpacing: -1,
      ),
      headlineSmall: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        letterSpacing: -.5,
      ),
      titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      bodyMedium: TextStyle(fontSize: 14, height: 1.5),
      bodySmall: TextStyle(fontSize: 12, color: palette.muted),
    ),
    dividerColor: palette.border,
    dividerTheme: DividerThemeData(
      color: palette.border,
      space: 1,
      thickness: .6,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: palette.raised,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: TextStyle(color: palette.text, fontSize: 12),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.background,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: palette.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: palette.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: accent),
      ),
      labelStyle: TextStyle(color: palette.muted),
    ),
    cardTheme: CardThemeData(
      color: palette.surface,
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: palette.border, width: .6),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: palette.muted),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: palette.raised,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: palette.raised,
      contentTextStyle: TextStyle(color: palette.text),
    ),
  );
}

Future<void> guard(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Invalid argument(s): ', '')),
        ),
      );
    }
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });
  final IconData icon;
  final String title, subtitle;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: context.accentColor.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Icon(icon, size: 30, color: context.accentColor),
          ),
          const SizedBox(height: 20),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(color: context.palette.muted, height: 1.6),
            textAlign: TextAlign.center,
          ),
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    ),
  );
}
