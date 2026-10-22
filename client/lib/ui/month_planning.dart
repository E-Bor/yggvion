import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;
import '../domain/models.dart';
import 'calendar.dart';
import 'providers.dart';
import 'theme.dart';

Future<TimeRange?> chooseMonthPlan(
  BuildContext context, {
  required Task task,
  required DateTime day,
}) {
  if (MediaQuery.sizeOf(context).width < 600) {
    return showModalBottomSheet<TimeRange>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      // Vertical gestures belong to the time grid, including its resize handles.
      enableDrag: false,
      showDragHandle: false,
      backgroundColor: Palette.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .9,
          child: MonthPlanningEditor(task: task, day: day),
        ),
      ),
    );
  }
  return showDialog<TimeRange>(
    context: context,
    builder: (context) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 600,
        height: math.min(800, MediaQuery.sizeOf(context).height - 64),
        child: MonthPlanningEditor(task: task, day: day),
      ),
    ),
  );
}

/// Holds only a preview. The calendar caller persists the confirmed interval.
class MonthPlanningEditor extends ConsumerStatefulWidget {
  const MonthPlanningEditor({super.key, required this.task, required this.day});
  final Task task;
  final DateTime day;
  @override
  ConsumerState<MonthPlanningEditor> createState() =>
      _MonthPlanningEditorState();
}

class _MonthPlanningEditorState extends ConsumerState<MonthPlanningEditor> {
  late int minutes;
  late final DateTime scrollFocus;
  TimeBlock? draft;
  @override
  void initState() {
    super.initState();
    final repo = ref.read(appProvider);
    minutes = repo.snapshot.settings.defaultMinutes;
    final zone = tz.getLocation(repo.snapshot.settings.timezone);
    final now = tz.TZDateTime.from(repo.now(), zone);
    scrollFocus = tz.TZDateTime(
      zone,
      widget.day.year,
      widget.day.month,
      widget.day.day,
      dayKey(widget.day) == dayKey(now) ? now.hour : 9,
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(appProvider);
    final zone = tz.getLocation(repo.snapshot.settings.timezone);
    final block = draft;
    final start = block == null ? null : tz.TZDateTime.from(block.start, zone);
    final end = block == null ? null : tz.TZDateTime.from(block.end, zone);
    final sameDay = start == null || dayKey(start) == dayKey(end!);
    final conflicts = block == null
        ? <Task>[]
        : [
            for (final other in repo.snapshot.blocks)
              if (!other.historical &&
                  other.start.isBefore(block.end) &&
                  other.end.isAfter(block.start))
                if (repo.snapshot.task(other.taskId) case final task?)
                  if (!task.isBirthday) task,
          ];
    final mobile = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: EdgeInsets.all(mobile ? 16 : 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      DateFormat('d MMMM · EEEE', 'ru').format(widget.day),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.task.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Palette.muted,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Закрыть выбор времени',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(
                Icons.schedule_rounded,
                color: context.accentColor,
                size: 21,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  start == null
                      ? 'Выберите время'
                      : '${DateFormat('HH:mm').format(start)} — ${DateFormat('HH:mm').format(end!)}',
                  key: const ValueKey('month-plan-time'),
                  style: TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.w600,
                    color: start == null ? Palette.muted : context.accentColor,
                  ),
                ),
              ),
              Tooltip(
                message: 'Часовой пояс из настроек',
                child: Text(
                  tz.TZDateTime.from(scrollFocus, zone).timeZoneName,
                  style: const TextStyle(color: Palette.muted, fontSize: 11),
                ),
              ),
            ],
          ),
          if (!sameDay)
            Text(
              'Окончание ${DateFormat('d MMMM', 'ru').format(end)}',
              key: const ValueKey('month-plan-end-date'),
              style: const TextStyle(fontSize: 12, color: Palette.muted),
            ),
          const SizedBox(height: 4),
          Text(
            formatDuration(Duration(minutes: minutes)),
            key: const ValueKey('month-plan-duration'),
            style: const TextStyle(color: Palette.muted, fontSize: 12),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: CalendarPane(
              key: const ValueKey('month-plan-calendar'),
              initialDate: widget.day,
              initialTime: scrollFocus,
              showToolbar: false,
              planningPreview: true,
              timeEntryTask: widget.task,
              entries: block == null ? const [] : [block],
              selectionMinutes: minutes,
              onEntriesChanged: (entries) => setState(() {
                draft = entries.singleOrNull;
                if (draft != null) minutes = draft!.duration.inMinutes;
              }),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            conflicts.isNotEmpty
                ? 'Пересекается: ${conflicts.map((t) => t.title).toSet().join(', ')}'
                : mobile
                ? 'Коснитесь времени или удерживайте и тяните. Края блока меняют длительность.'
                : 'Нажмите на время или выделите интервал. Блок можно перемещать и растягивать.',
            key: const ValueKey('month-plan-hint'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              height: 1.4,
              color: Palette.muted,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Отмена'),
              ),
              const Spacer(),
              FilledButton.icon(
                key: const ValueKey('confirm-month-plan'),
                onPressed: block == null
                    ? null
                    : () => Navigator.pop(
                        context,
                        TimeRange(block.start, block.end),
                      ),
                icon: const Icon(Icons.check_rounded, size: 18),
                label: const Text('Запланировать'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
