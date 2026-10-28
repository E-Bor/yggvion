import '../l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers.dart';
import 'theme.dart';

class CalendarZoomButton extends ConsumerWidget {
  const CalendarZoomButton({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
    key: const ValueKey('calendar-zoom'),
    tooltip: tr("Масштаб календаря"),
    visualDensity: VisualDensity.compact,
    icon: const Icon(Icons.zoom_in_rounded, size: 21),
    onPressed: () => showDialog<void>(
      context: context,
      builder: (dialog) => Consumer(
        builder: (context, ref, _) {
          final repo = ref.watch(appProvider);
          return AlertDialog(
            title: Text(tr("Масштаб календаря")),
            content: SizedBox(
              width: 280,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    repo.calendarZoom == 0
                        ? tr("Весь день")
                        : '${(repo.calendarZoom * 100).round()}%',
                  ),
                  Slider(
                    key: const ValueKey('calendar-zoom-slider'),
                    value: repo.calendarZoom,
                    min: 0,
                    max: 3,
                    onChanged: repo.previewCalendarZoom,
                    onChangeEnd: (value) =>
                        guard(context, () => repo.setCalendarZoom(value)),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: () =>
                            guard(context, () => repo.setCalendarZoom(0)),
                        child: Text(tr("Весь день")),
                      ),
                      TextButton(
                        onPressed: () =>
                            guard(context, () => repo.setCalendarZoom(1)),
                        child: Text(tr("Обычный")),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: Text(tr("Готово")),
              ),
            ],
          );
        },
      ),
    ),
  );
}
