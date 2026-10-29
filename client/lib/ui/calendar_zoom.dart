import '../l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers.dart';
import 'theme.dart';

class CalendarZoomSetting extends ConsumerWidget {
  const CalendarZoomSetting({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(appProvider);
    final label = repo.calendarZoom == 0
        ? tr("Весь день")
        : '${(repo.calendarZoom * 100).round()}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(tr("Масштаб календаря"))),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(color: context.accentColor)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          tr("Сохраняется на этом устройстве"),
          style: TextStyle(color: context.palette.muted, fontSize: 12),
        ),
        Slider(
          key: const ValueKey('calendar-zoom-slider'),
          value: repo.calendarZoom,
          min: 0,
          max: 3,
          divisions: 30,
          label: label,
          onChanged: repo.previewCalendarZoom,
          onChangeEnd: (value) =>
              guard(context, () => repo.setCalendarZoom(value)),
        ),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              key: const ValueKey('calendar-zoom-fit'),
              onPressed: () => guard(context, () => repo.setCalendarZoom(0)),
              child: Text(tr("Весь день")),
            ),
            TextButton(
              key: const ValueKey('calendar-zoom-normal'),
              onPressed: () => guard(context, () => repo.setCalendarZoom(1)),
              child: Text(tr("Обычный")),
            ),
          ],
        ),
      ],
    );
  }
}
