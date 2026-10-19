import 'package:flutter/material.dart';
import '../domain/models.dart';

abstract final class Palette {
  static const background = Color(0xff111419),
      surface = Color(0xff1a1e25),
      raised = Color(0xff242b35),
      border = Color(0xff303744),
      text = Color(0xffe8ecf2),
      muted = Color(0xff929dad),
      blue = Color(AppSettings.defaultTaskColor),
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
  }) => Color.lerp(
    surface,
    accent.withValues(alpha: 1),
    subdued
        ? .08
        : selected
        ? .33
        : .26,
  )!;
}

class TaskColorPicker extends StatelessWidget {
  const TaskColorPicker({
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
              key: ValueKey('task-color-$i'),
              borderRadius: BorderRadius.circular(12),
              onTap: () => onChanged(Palette.projects[i].toARGB32()),
              child: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Palette.taskSurface(Palette.projects[i]),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Palette.projects[i],
                    width: value == Palette.projects[i].toARGB32() ? 2 : .7,
                  ),
                ),
                child: Icon(
                  value == Palette.projects[i].toARGB32()
                      ? Icons.check_rounded
                      : Icons.circle,
                  color: Palette.projects[i],
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

ThemeData appTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: Palette.blue,
        brightness: Brightness.dark,
        surface: Palette.surface,
      ).copyWith(
        primary: Palette.blue,
        onPrimary: Palette.background,
        primaryContainer: Palette.taskSurface(Palette.blue, selected: true),
        onPrimaryContainer: Palette.blue,
        secondary: Palette.blue,
        onSecondary: Palette.background,
        secondaryContainer: Palette.taskSurface(Palette.blue),
        onSecondaryContainer: Palette.blue,
        outline: Palette.border,
      );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: Palette.background,
    fontFamily: 'Inter',
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(4),
      radius: const Radius.circular(4),
      thumbColor: WidgetStatePropertyAll(Palette.muted.withValues(alpha: .35)),
    ),
    textTheme: const TextTheme(
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
      bodySmall: TextStyle(fontSize: 12, color: Palette.muted),
    ),
    dividerColor: Palette.border,
    dividerTheme: const DividerThemeData(
      color: Palette.border,
      space: 1,
      thickness: .6,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: Palette.raised,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(color: Palette.text, fontSize: 12),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Palette.background,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Palette.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Palette.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Palette.blue),
      ),
      labelStyle: const TextStyle(color: Palette.muted),
    ),
    cardTheme: CardThemeData(
      color: Palette.surface,
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Palette.border, width: .6),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Palette.surface,
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
      style: IconButton.styleFrom(foregroundColor: Palette.muted),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: Palette.raised,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Palette.raised,
      contentTextStyle: TextStyle(color: Palette.text),
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
              color: Palette.blue.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Icon(icon, size: 30, color: Palette.blue),
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
            style: const TextStyle(color: Palette.muted, height: 1.6),
            textAlign: TextAlign.center,
          ),
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    ),
  );
}
