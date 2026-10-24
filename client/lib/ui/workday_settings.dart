import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers.dart';
import 'theme.dart';

import '../domain/workday.dart';

class WorkdaySettings extends ConsumerWidget {
  const WorkdaySettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(appProvider);
    final settings = repo.snapshot.settings;
    String label(int minute) =>
        '${(minute ~/ 60 % 24).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}${minute >= 1440 ? ' · следующий день' : ''}';
    Future<void> pick(bool start) async {
      final value = start ? settings.workdayStart : settings.workdayEnd;
      final time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: value ~/ 60 % 24, minute: value % 60),
        helpText: start ? 'Начало рабочего дня' : 'Конец рабочего дня',
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        ),
      );
      if (time == null || !context.mounted) return;
      final minute = time.hour * 60 + time.minute;
      final current = repo.snapshot.settings;
      final begin = start ? minute : current.workdayStart;
      final end = WorkdaySchedule.endMinute(
        begin,
        start ? current.workdayEnd % 1440 : minute,
      );
      await guard(
        context,
        () => repo.updateWorkdaySettings(begin, end, current.workdays),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Начало и конец учитываются автоматически. Передвиньте метку в календаре, чтобы скорректировать время конкретного дня, в том числе задним числом. Если окончание раньше начала, рабочий день продолжается после полуночи.',
          style: TextStyle(
            color: context.palette.muted,
            fontSize: 12,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('workday-start-setting'),
              icon: const Icon(Icons.wb_sunny_outlined, size: 18),
              onPressed: () => pick(true),
              label: Text('Начало · ${label(settings.workdayStart)}'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('workday-end-setting'),
              icon: const Icon(Icons.bedtime_outlined, size: 18),
              onPressed: () => pick(false),
              label: Text('Конец · ${label(settings.workdayEnd)}'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var day = 1; day <= 7; day++)
              FilterChip(
                key: ValueKey('workday-weekday-$day'),
                label: Text(
                  const ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'][day - 1],
                ),
                showCheckmark: false,
                selected: settings.workdays.contains(day),
                onSelected: (selected) => guard(context, () {
                  final current = repo.snapshot.settings;
                  final days = {...current.workdays};
                  selected ? days.add(day) : days.remove(day);
                  return repo.updateWorkdaySettings(
                    current.workdayStart,
                    current.workdayEnd,
                    days.toList(),
                  );
                }),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'Часовой пояс: ${settings.timezone}. Настройки сохраняются сразу. Дни с ручными изменениями сохраняют свои границы.',
          style: TextStyle(
            color: context.palette.muted,
            fontSize: 11,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}
