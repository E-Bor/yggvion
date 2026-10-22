import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;
import '../domain/models.dart';
import 'calendar.dart';
import 'providers.dart';
import 'theme.dart';

class SessionEditor extends ConsumerStatefulWidget {
  const SessionEditor({super.key, required this.task, this.session});
  final Task task;
  final WorkSession? session;
  @override
  ConsumerState<SessionEditor> createState() => _SessionEditorState();
}

class _SessionEditorState extends ConsumerState<SessionEditor> {
  late DateTime focus;
  late DateTime scrollFocus;
  List<TimeBlock> entries = [];
  bool saving = false;
  String? error;
  @override
  void initState() {
    super.initState();
    final repo = ref.read(appProvider);
    final plans = repo.snapshot.taskBlocks(widget.task.id);
    focus =
        widget.session?.start ??
        plans.where((b) => !b.start.isAfter(repo.now())).lastOrNull?.start ??
        plans.firstOrNull?.start ??
        repo.now().subtract(const Duration(minutes: 30));
    scrollFocus = focus;
    if (widget.session != null) {
      entries = [
        draft(widget.session!.start, widget.session!.end ?? repo.now()),
      ];
    }
  }

  TimeBlock draft(DateTime start, DateTime end) {
    final repo = ref.read(appProvider);
    return TimeBlock(
      TimeBlock.create(
        repo.newId(),
        widget.task.id,
        start,
        end,
        timezone: repo.snapshot.settings.timezone,
        reminders: const [],
      ),
    );
  }

  Future<void> save() async {
    if (saving) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await ref
          .read(appProvider)
          .saveSessionRanges(
            widget.task.id,
            entries.map((b) => TimeRange(b.start, b.end)).toList(),
            replacing: widget.session,
          );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e.toString().replaceFirst('Invalid argument(s): ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(appProvider), size = MediaQuery.sizeOf(context);
    final plans = repo.snapshot.taskBlocks(widget.task.id);
    final zone = tz.getLocation(repo.snapshot.settings.timezone);
    final available = availablePlannedTime(plans, repo.now());
    final total = unionRanges(
      entries.map((b) => TimeRange(b.start, b.end)),
    ).fold(Duration.zero, (value, range) => value + range.duration);
    final mobile = size.width < 600;
    return Dialog(
      insetPadding: EdgeInsets.all(mobile ? 8 : 28),
      child: SizedBox(
        width: 900,
        height: math.min(800, size.height - (mobile ? 32 : 80)),
        child: Padding(
          padding: EdgeInsets.all(mobile ? 12 : 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.timelapse_rounded,
                    color: context.palette.pink,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Потраченное время',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Закрыть учёт времени',
                    onPressed: saving ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
              Text(
                widget.task.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: context.palette.muted, fontSize: 13),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('use-planned-time'),
                  onPressed: saving || available.isEmpty
                      ? null
                      : () => setState(() {
                          entries = availablePlannedTime(plans, repo.now())
                              .map((range) => draft(range.start, range.end))
                              .toList();
                          if (entries.isEmpty) return;
                          focus = entries.first.start;
                          scrollFocus = focus;
                          error = null;
                        }),
                  icon: const Icon(Icons.done_all_rounded, size: 17),
                  label: const Text('Затрекать всё доступное время'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  mobile
                      ? 'Удерживайте и тяните, чтобы отметить время. Можно добавить несколько интервалов.'
                      : 'Выделите один или несколько интервалов. Контур — план задачи.',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.palette.muted,
                    height: 1.4,
                  ),
                ),
              ),
              if (entries.isNotEmpty)
                SizedBox(
                  height: 38,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: entries.length,
                    separatorBuilder: (_, index) => const SizedBox(width: 6),
                    itemBuilder: (_, index) {
                      final entry = entries[index];
                      return InputChip(
                        label: Text(
                          '${DateFormat('d MMM, HH:mm', 'ru').format(tz.TZDateTime.from(entry.start, zone))} · ${formatDuration(entry.duration)}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        onPressed: () => setState(() {
                          focus = entry.start;
                          scrollFocus = focus;
                        }),
                        onDeleted: saving
                            ? null
                            : () => setState(
                                () => entries = entries
                                    .where((b) => b.id != entry.id)
                                    .toList(),
                              ),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 8),
              Expanded(
                child: IgnorePointer(
                  ignoring: saving,
                  child: CalendarPane(
                    key: const ValueKey('time-entry-calendar'),
                    initialDate: focus,
                    initialTime: scrollFocus,
                    onDateChanged: (value) => setState(() => focus = value),
                    timeEntryTask: widget.task,
                    entries: entries,
                    onEntriesChanged: (value) => setState(() {
                      entries = value;
                      error = null;
                    }),
                  ),
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          formatDuration(total),
                          key: const ValueKey('time-entry-total'),
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: context.palette.pink,
                          ),
                        ),
                        Text(
                          'Пересечения считаются один раз',
                          style: TextStyle(
                            fontSize: 10,
                            color: context.palette.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: saving ? null : () => Navigator.pop(context),
                    child: const Text('Отмена'),
                  ),
                  const SizedBox(width: 6),
                  FilledButton(
                    key: const ValueKey('save-time-entries'),
                    onPressed: saving || entries.isEmpty ? null : save,
                    child: const Text('ОК'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
