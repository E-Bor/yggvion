import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;
import '../domain/models.dart';
import '../data/repository.dart';
import '../domain/recurrence.dart';
import 'providers.dart';
import 'task_editor.dart';
import 'theme.dart';

class CalendarToolbar extends StatelessWidget {
  const CalendarToolbar({
    super.key,
    required this.date,
    required this.view,
    required this.now,
    required this.timezone,
    required this.onDateChanged,
    required this.onViewChanged,
    this.showDate = true,
  });
  final DateTime date, now;
  final CalendarView view;
  final String timezone;
  final ValueChanged<DateTime> onDateChanged;
  final ValueChanged<CalendarView> onViewChanged;
  final bool showDate;

  static String dateLabel(DateTime date, CalendarView view) {
    if (view == CalendarView.month) {
      return DateFormat('LLLL y', 'ru').format(date);
    }
    if (view == CalendarView.day) {
      return DateFormat('d MMMM y', 'ru').format(date);
    }
    final first = DateTime.utc(
      date.year,
      date.month,
      date.day - (view == CalendarView.week ? date.weekday - 1 : 0),
    );
    final last = first.add(Duration(days: view.days - 1));
    final pattern = first.year != last.year
        ? 'd MMM y'
        : first.month != last.month
        ? 'd MMM'
        : 'd';
    return '${DateFormat(pattern, 'ru').format(first)} — ${DateFormat('d MMM y', 'ru').format(last)}';
  }

  void navigate(int direction) {
    final zone = tz.getLocation(timezone);
    onDateChanged(
      view == CalendarView.month
          ? tz.TZDateTime(zone, date.year, date.month + direction, 1)
          : tz.TZDateTime(
              zone,
              date.year,
              date.month,
              date.day + view.days * direction,
            ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final stacked = showDate && constraints.maxWidth < 460;
      final label = Text(
        dateLabel(date, view),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      );
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (stacked)
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 4),
              child: label,
            ),
          Row(
            children: [
              IconButton(
                tooltip: 'Назад',
                onPressed: () => navigate(-1),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              IconButton(
                tooltip: 'Вперёд',
                onPressed: () => navigate(1),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.chevron_right_rounded),
              ),
              TextButton(
                onPressed: () => onDateChanged(now),
                child: const Text('Сегодня'),
              ),
              const SizedBox(width: 12),
              if (showDate && !stacked)
                Expanded(child: label)
              else
                const Spacer(),
              const SizedBox(width: 12),
              DropdownButtonHideUnderline(
                child: DropdownButton<CalendarView>(
                  value: view,
                  isDense: true,
                  style: const TextStyle(
                    color: Palette.muted,
                    fontSize: 13,
                    fontFamily: 'Inter',
                  ),
                  borderRadius: BorderRadius.circular(12),
                  items: CalendarView.values
                      .map(
                        (v) => DropdownMenuItem(value: v, child: Text(v.label)),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) onViewChanged(value);
                  },
                ),
              ),
            ],
          ),
        ],
      );
    },
  );
}

class CalendarPane extends ConsumerStatefulWidget {
  const CalendarPane({
    super.key,
    this.selectedTask,
    this.onPlaced,
    this.projectId = '',
    this.initialDate,
    this.planner = false,
    this.showToolbar = true,
  });
  final Task? selectedTask;
  final VoidCallback? onPlaced;
  final String projectId;
  final DateTime? initialDate;
  final bool planner;
  final bool showToolbar;
  @override
  ConsumerState<CalendarPane> createState() => _CalendarPaneState();
}

class _CalendarPaneState extends ConsumerState<CalendarPane> {
  late DateTime date;
  final scroll = ScrollController();
  final horizontal = ScrollController();
  DateTime? selectionStart, selectionEnd, selectionAnchor;
  String? error;
  int expansion = 0;
  tz.Location get _zone =>
      tz.getLocation(ref.read(appProvider).snapshot.settings.timezone);
  DateTime get _clock => _display(ref.read(appProvider).now());
  DateTime _display(DateTime value) => tz.TZDateTime.from(value, _zone);
  DateTime _date(
    int year,
    int month,
    int day, [
    int hour = 0,
    int minute = 0,
  ]) => tz.TZDateTime(_zone, year, month, day, hour, minute);
  DateTime _midnight(DateTime value) {
    final local = _display(value);
    return _date(local.year, local.month, local.day);
  }

  int _dayIndex(DateTime day, DateTime first) => DateTime.utc(
    day.year,
    day.month,
    day.day,
  ).difference(DateTime.utc(first.year, first.month, first.day)).inDays;
  static const hourHeight = 72.0, gutter = 48.0;
  @override
  void initState() {
    super.initState();
    date = _midnight(widget.initialDate ?? _clock);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) {
        scroll.jumpTo(
          math.min(
            scroll.position.maxScrollExtent,
            math.max(0, (_clock.hour - 1) * hourHeight),
          ),
        );
      }
      expand();
    });
  }

  @override
  void didUpdateWidget(covariant CalendarPane old) {
    super.didUpdateWidget(old);
    if (widget.initialDate != null && widget.initialDate != old.initialDate) {
      date = _midnight(widget.initialDate!);
      expand();
    }
  }

  void expand() {
    final generation = ++expansion;
    RecurrenceService(ref.read(appProvider))
        .expand(
          date.subtract(const Duration(days: 7)),
          date.add(const Duration(days: 42)),
        )
        .then(
          (_) {
            if (mounted && generation == expansion) {
              setState(() => error = null);
            }
          },
          onError: (Object e) {
            if (mounted && generation == expansion) {
              setState(() => error = 'Не удалось раскрыть повторения: $e');
            }
          },
        );
  }

  @override
  void dispose() {
    scroll.dispose();
    horizontal.dispose();
    super.dispose();
  }

  DateTime firstDay(CalendarView view) => view == CalendarView.week
      ? _date(date.year, date.month, date.day - (date.weekday - 1))
      : date;
  DateTime at(Offset position, double width, int count, DateTime first) {
    final column = ((position.dx - gutter) / width).floor().clamp(0, count - 1);
    final minutes = ((position.dy / hourHeight * 60) / 5).round() * 5;
    return _date(
      first.year,
      first.month,
      first.day + column,
      0,
      minutes.clamp(0, 1435),
    );
  }

  Future<void> place(DateTime start, DateTime end) async {
    if (widget.selectedTask != null) {
      await guard(context, () async {
        await ref.read(appProvider).schedule(widget.selectedTask!, start, end);
        widget.onPlaced?.call();
      });
    } else {
      await openTask(context, start: start, end: end);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(appProvider),
        view = widget.planner ? repo.plannerView : repo.calendarView,
        first = firstDay(view);
    final blocks = repo.snapshot.blocks.where((b) {
      final t = repo.snapshot.task(b.taskId);
      return t != null &&
          (widget.projectId.isEmpty || t.projectId == widget.projectId);
    }).toList();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Palette.border, width: .6),
      ),
      child: Column(
        children: [
          if (widget.showToolbar)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
              child: CalendarToolbar(
                date: date,
                view: view,
                now: _clock,
                timezone: repo.snapshot.settings.timezone,
                onDateChanged: (value) {
                  setState(() => date = _midnight(value));
                  expand();
                },
                onViewChanged: (value) {
                  guard(
                    context,
                    () => repo.setView(value, planner: widget.planner),
                  );
                  expand();
                },
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (widget.showToolbar || error != null) const Divider(),
          Expanded(
            child: view == CalendarView.month
                ? _month(repo, blocks)
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final count = view.days;
                      final width = math.max(
                        view == CalendarView.day ? 0.0 : 105.0,
                        (constraints.maxWidth - gutter) / count,
                      );
                      final fullWidth = gutter + count * width;
                      return Scrollbar(
                        controller: horizontal,
                        child: SingleChildScrollView(
                          controller: horizontal,
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: fullWidth,
                            child: Column(
                              children: [
                                SizedBox(
                                  height: 59,
                                  child: Row(
                                    children: [
                                      const SizedBox(width: gutter),
                                      for (var i = 0; i < count; i++)
                                        SizedBox(
                                          width: width,
                                          child: _dayHeader(
                                            _date(
                                              first.year,
                                              first.month,
                                              first.day + i,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const Divider(),
                                Expanded(
                                  child: Scrollbar(
                                    controller: scroll,
                                    child: SingleChildScrollView(
                                      controller: scroll,
                                      child: SizedBox(
                                        height: 24 * hourHeight,
                                        width: fullWidth,
                                        child: CalendarGestureSurface(
                                          key: const ValueKey(
                                            'calendar-grid-gestures',
                                          ),
                                          onTap: (position) {
                                            if (position.dx < gutter) {
                                              return;
                                            }
                                            final start = at(
                                              position,
                                              width,
                                              count,
                                              first,
                                            );
                                            place(
                                              start,
                                              start.add(
                                                Duration(
                                                  minutes: repo
                                                      .snapshot
                                                      .settings
                                                      .defaultMinutes,
                                                ),
                                              ),
                                            );
                                          },
                                          onStart: (position) {
                                            if (position.dx < gutter) {
                                              return;
                                            }
                                            setState(() {
                                              selectionStart = at(
                                                position,
                                                width,
                                                count,
                                                first,
                                              );
                                              selectionAnchor = selectionStart;
                                              selectionEnd = selectionStart!
                                                  .add(
                                                    Duration(
                                                      minutes: repo
                                                          .snapshot
                                                          .settings
                                                          .defaultMinutes,
                                                    ),
                                                  );
                                            });
                                          },
                                          onUpdate: (position) {
                                            if (selectionStart == null) return;
                                            setState(() {
                                              final end = at(
                                                position,
                                                width,
                                                count,
                                                first,
                                              );
                                              final anchor = selectionAnchor!;
                                              selectionStart =
                                                  end.isBefore(anchor)
                                                  ? end
                                                  : anchor;
                                              selectionEnd = end.isAfter(anchor)
                                                  ? end
                                                  : anchor.add(
                                                      const Duration(
                                                        minutes: 5,
                                                      ),
                                                    );
                                            });
                                            final y =
                                                position.dy - scroll.offset;
                                            if (y >
                                                    constraints.maxHeight -
                                                        100 &&
                                                scroll.offset <
                                                    scroll
                                                        .position
                                                        .maxScrollExtent) {
                                              scroll.jumpTo(
                                                math.min(
                                                  scroll
                                                      .position
                                                      .maxScrollExtent,
                                                  scroll.offset + 12,
                                                ),
                                              );
                                            }
                                            if (y < 40 && scroll.offset > 0) {
                                              scroll.jumpTo(
                                                math.max(0, scroll.offset - 12),
                                              );
                                            }
                                          },
                                          onCancel: () => setState(() {
                                            selectionStart = null;
                                            selectionEnd = null;
                                          }),
                                          onEnd: () {
                                            final start = selectionStart,
                                                end = selectionEnd;
                                            setState(() {
                                              selectionStart = null;
                                              selectionEnd = null;
                                            });
                                            if (start != null && end != null) {
                                              place(start, end);
                                            }
                                          },
                                          child: Stack(
                                            clipBehavior: Clip.hardEdge,
                                            children: [
                                              Positioned.fill(
                                                child: CustomPaint(
                                                  painter: _GridPainter(
                                                    count: count,
                                                    columnWidth: width,
                                                    hourHeight: hourHeight,
                                                    gutter: gutter,
                                                  ),
                                                ),
                                              ),
                                              for (var h = 0; h < 24; h++)
                                                Positioned(
                                                  left: 8,
                                                  top: h * hourHeight + 5,
                                                  child: Text(
                                                    '${h.toString().padLeft(2, '0')}:00',
                                                    style: const TextStyle(
                                                      fontSize: 10,
                                                      color: Palette.muted,
                                                    ),
                                                  ),
                                                ),
                                              for (
                                                var day = 0;
                                                day < count;
                                                day++
                                              )
                                                ..._dayBlocks(
                                                  repo,
                                                  blocks,
                                                  _date(
                                                    first.year,
                                                    first.month,
                                                    first.day + day,
                                                  ),
                                                  gutter + width * day,
                                                  width,
                                                ),
                                              for (
                                                var day = 0;
                                                day < count;
                                                day++
                                              )
                                                ..._tracks(
                                                  repo,
                                                  _date(
                                                    first.year,
                                                    first.month,
                                                    first.day + day,
                                                  ),
                                                  gutter + width * day,
                                                ),
                                              if (!_clock.isBefore(first) &&
                                                  _clock.isBefore(
                                                    _date(
                                                      first.year,
                                                      first.month,
                                                      first.day + count,
                                                    ),
                                                  ))
                                                Positioned(
                                                  left:
                                                      gutter +
                                                      _dayIndex(_clock, first) *
                                                          width,
                                                  top:
                                                      (_clock.hour +
                                                          _clock.minute / 60) *
                                                      hourHeight,
                                                  right:
                                                      fullWidth -
                                                      gutter -
                                                      (_dayIndex(
                                                                _clock,
                                                                first,
                                                              ) +
                                                              1) *
                                                          width,
                                                  child: IgnorePointer(
                                                    child: Row(
                                                      children: [
                                                        Container(
                                                          width: 6,
                                                          height: 6,
                                                          decoration:
                                                              const BoxDecoration(
                                                                color: Palette
                                                                    .pink,
                                                                shape: BoxShape
                                                                    .circle,
                                                              ),
                                                        ),
                                                        Expanded(
                                                          child: Container(
                                                            height: 1,
                                                            color: Palette.pink
                                                                .withValues(
                                                                  alpha: .7,
                                                                ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              if (selectionStart != null &&
                                                  selectionEnd != null)
                                                Positioned(
                                                  left:
                                                      gutter +
                                                      _dayIndex(
                                                            selectionStart!,
                                                            first,
                                                          ) *
                                                          width +
                                                      12,
                                                  top:
                                                      (selectionStart!.hour +
                                                          selectionStart!
                                                                  .minute /
                                                              60) *
                                                      hourHeight,
                                                  width: width - 18,
                                                  height: math.max(
                                                    12,
                                                    selectionEnd!
                                                            .difference(
                                                              selectionStart!,
                                                            )
                                                            .inMinutes /
                                                        60 *
                                                        hourHeight,
                                                  ),
                                                  child: IgnorePointer(
                                                    child: Container(
                                                      decoration: BoxDecoration(
                                                        color: Palette.blue
                                                            .withValues(
                                                              alpha: .18,
                                                            ),
                                                        border: Border.all(
                                                          color: Palette.blue,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                      ),
                                                      padding:
                                                          const EdgeInsets.all(
                                                            8,
                                                          ),
                                                      child: Text(
                                                        widget
                                                                .selectedTask
                                                                ?.title ??
                                                            'Новая задача',
                                                        style: const TextStyle(
                                                          fontSize: 12,
                                                          color: Palette.blue,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _dayHeader(DateTime day) {
    final today = _midnight(day) == _midnight(_clock);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          DateFormat('EEE', 'ru').format(day),
          style: TextStyle(
            fontSize: 11,
            color: today ? Palette.blue : Palette.muted,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: today ? Palette.blue : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            '${day.day}',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: today ? Palette.background : Palette.text,
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _dayBlocks(
    Repository repo,
    List<TimeBlock> blocks,
    DateTime day,
    double left,
    double width,
  ) {
    final end = _date(day.year, day.month, day.day + 1);
    final list =
        blocks
            .where((b) => b.start.isBefore(end) && b.end.isAfter(day))
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    final laneEnds = <DateTime>[], lanes = <String, int>{};
    for (final b in list) {
      var lane = laneEnds.indexWhere((e) => !e.isAfter(b.start));
      if (lane < 0) {
        lane = laneEnds.length;
        laneEnds.add(b.end);
      } else {
        laneEnds[lane] = b.end;
      }
      lanes[b.id] = lane;
    }
    final laneWidth = (width - 18) / math.max(1, laneEnds.length);
    return list.map((b) {
      final start = b.start.isBefore(day) ? day : _display(b.start),
          finish = b.end.isAfter(end) ? end : _display(b.end);
      final top = (start.hour + start.minute / 60) * hourHeight;
      final height = math.max(
        22.0,
        finish.difference(start).inMinutes / 60 * hourHeight - 3,
      );
      return Positioned(
        key: ValueKey('${b.id}-${dayKey(day)}'),
        left: left + 12 + lanes[b.id]! * laneWidth,
        top: top,
        width: laneWidth - 3,
        height: height,
        child: CalendarBlock(
          block: b,
          day: day,
          hourHeight: hourHeight,
          columnWidth: width,
        ),
      );
    }).toList();
  }

  List<Widget> _tracks(Repository repo, DateTime day, double left) {
    final end = _date(day.year, day.month, day.day + 1);
    final sessions = repo.snapshot.sessions;
    return sessions
        .where(
          (s) =>
              !s.discarded &&
              s.start.isBefore(end) &&
              (s.end ?? _clock).isAfter(day),
        )
        .where(
          (s) =>
              widget.projectId.isEmpty ||
              repo.snapshot.task(s.taskId)?.projectId == widget.projectId,
        )
        .map((s) {
          final start = s.start.isBefore(day) ? day : _display(s.start);
          final finish = (s.end ?? _clock).isAfter(end)
              ? end
              : _display(s.end ?? _clock);
          final task = repo.snapshot.task(s.taskId);
          return Positioned(
            left: left + 3,
            top: (start.hour + start.minute / 60) * hourHeight,
            width: 5,
            height: math.max(
              3,
              finish.difference(start).inMinutes / 60 * hourHeight,
            ),
            child: Tooltip(
              message:
                  '${task?.title ?? 'Работа'} · ${formatDuration(finish.difference(start))}',
              child: GestureDetector(
                onTap: task == null
                    ? null
                    : () => editSession(context, task, session: s),
                child: Container(
                  decoration: BoxDecoration(
                    color: s.running
                        ? Palette.pink
                        : Palette.pink.withValues(alpha: .55),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          );
        })
        .toList();
  }

  Widget _month(Repository repo, List<TimeBlock> blocks) {
    final start = _date(date.year, date.month, 1);
    final first = _date(date.year, date.month, 1 - (start.weekday - 1));
    return LayoutBuilder(
      builder: (context, c) => GridView.builder(
        itemCount: 42,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 7,
          mainAxisExtent: math.max(105, c.maxHeight / 6),
        ),
        itemBuilder: (context, index) {
          final day = _date(first.year, first.month, first.day + index),
              end = _date(first.year, first.month, first.day + index + 1);
          final items =
              blocks
                  .where((b) => b.start.isBefore(end) && b.end.isAfter(day))
                  .toList()
                ..sort((a, b) => a.start.compareTo(b.start));
          return InkWell(
            onTap: () => place(
              day.add(const Duration(hours: 9)),
              day.add(
                Duration(
                  hours: 9,
                  minutes: repo.snapshot.settings.defaultMinutes,
                ),
              ),
            ),
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  right: const BorderSide(color: Palette.border, width: .5),
                  bottom: const BorderSide(color: Palette.border, width: .5),
                ),
                color: _midnight(day) == _midnight(_clock)
                    ? Palette.blue.withValues(alpha: .04)
                    : null,
              ),
              padding: const EdgeInsets.all(5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${day.day}',
                    style: TextStyle(
                      color: day.month == date.month
                          ? Palette.text
                          : Palette.muted.withValues(alpha: .4),
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 5),
                  for (final b in items.take(3))
                    Builder(
                      builder: (_) {
                        final task = repo.snapshot.task(b.taskId)!;
                        return GestureDetector(
                          onTap: () =>
                              openTask(context, task: task, blockId: b.id),
                          onSecondaryTapDown: (d) => showCalendarBlockMenu(
                            context,
                            ref,
                            b,
                            d.globalPosition,
                          ),
                          onLongPressStart: (d) => showCalendarBlockMenu(
                            context,
                            ref,
                            b,
                            d.globalPosition,
                          ),
                          child: Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 3),
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Palette.taskSurface(
                                Color(repo.snapshot.taskColor(task)),
                                subdued: task.done || b.historical,
                              ),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              task.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                decoration: task.done
                                    ? TextDecoration.lineThrough
                                    : null,
                                color: Color(repo.snapshot.taskColor(task)),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  if (items.length > 3)
                    Text(
                      '+${items.length - 3}',
                      style: const TextStyle(
                        fontSize: 10,
                        color: Palette.muted,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class CalendarGestureSurface extends StatelessWidget {
  const CalendarGestureSurface({
    super.key,
    required this.onTap,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.onCancel,
    required this.child,
  });
  final ValueChanged<Offset> onTap, onStart, onUpdate;
  final VoidCallback onEnd, onCancel;
  final Widget child;
  @override
  Widget build(BuildContext context) => GestureDetector(
    supportedDevices: const {PointerDeviceKind.touch, PointerDeviceKind.stylus},
    behavior: HitTestBehavior.opaque,
    onLongPressStart: (d) {
      HapticFeedback.mediumImpact();
      onStart(d.localPosition);
    },
    onLongPressMoveUpdate: (d) => onUpdate(d.localPosition),
    onLongPressEnd: (_) => onEnd(),
    onLongPressCancel: onCancel,
    child: GestureDetector(
      // Two-finger pan/zoom belongs to the scroll view. A pressed trackpad
      // click is delivered as a mouse pointer and can still select a range.
      supportedDevices: const {PointerDeviceKind.mouse},
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) => onTap(d.localPosition),
      onPanStart: (d) => onStart(d.localPosition),
      onPanUpdate: (d) => onUpdate(d.localPosition),
      onPanEnd: (_) => onEnd(),
      onPanCancel: onCancel,
      child: child,
    ),
  );
}

Future<void> showCalendarBlockMenu(
  BuildContext context,
  WidgetRef ref,
  TimeBlock block,
  Offset position,
) async {
  final task = ref.read(appProvider).snapshot.task(block.taskId);
  if (task == null) return;
  final choice = await showMenu<String>(
    context: context,
    position: menuPosition(context, position),
    items: [
      const PopupMenuItem(value: 'task', child: Text('Открыть задачу')),
      const PopupMenuItem(
        value: 'edit',
        child: Text('Изменить время и напоминания'),
      ),
      const PopupMenuItem(value: 'add', child: Text('Добавить блок')),
      const PopupMenuItem(value: 'split', child: Text('Разделить блок')),
      if (!task.done)
        const PopupMenuItem(
          value: 'review',
          child: Text('Готово → создать проверку'),
        ),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'unschedule', child: Text('Убрать из плана')),
      const PopupMenuItem(value: 'delete', child: Text('Удалить задачу')),
    ],
  );
  if (choice == null || !context.mounted) return;
  await guard(context, () async {
    final repo = ref.read(appProvider);
    switch (choice) {
      case 'task':
        await openTask(context, task: task, blockId: block.id);
      case 'edit':
        await editBlock(context, block);
      case 'split':
        await repo.splitBlock(
          block,
          block.start.add(
            Duration(milliseconds: block.duration.inMilliseconds ~/ 2),
          ),
        );
      case 'review':
        await repo.completeForReview(task);
      case 'unschedule':
        await repo.unschedule(block);
      case 'delete':
        await deleteTask(context, ref, task);
      case 'add':
        final zone = tz.getLocation(repo.snapshot.settings.timezone);
        final at = await pickDateTime(
          context,
          tz.TZDateTime.from(block.end, zone),
        );
        if (at != null) {
          final start = tz.TZDateTime(
            zone,
            at.year,
            at.month,
            at.day,
            at.hour,
            at.minute,
          );
          await repo.schedule(
            task,
            start,
            start.add(Duration(minutes: repo.snapshot.settings.defaultMinutes)),
          );
        }
    }
  });
}

class CalendarBlock extends ConsumerStatefulWidget {
  const CalendarBlock({
    super.key,
    required this.block,
    required this.day,
    required this.hourHeight,
    required this.columnWidth,
  });
  final TimeBlock block;
  final DateTime day;
  final double hourHeight, columnWidth;
  @override
  ConsumerState<CalendarBlock> createState() => _CalendarBlockState();
}

class _CalendarBlockState extends ConsumerState<CalendarBlock> {
  Offset movement = Offset.zero;
  double startResize = 0, endResize = 0;
  bool editing = false;
  bool get mobile =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;
  int minutes(double pixels) =>
      (pixels / widget.hourHeight * 60 / 5).round() * 5;
  DateTime shift(DateTime value, int days, int mins) {
    final location = tz.getLocation(
      ref.read(appProvider).snapshot.settings.timezone,
    );
    final local = tz.TZDateTime.from(value, location);
    return tz.TZDateTime(
      location,
      local.year,
      local.month,
      local.day + days,
      local.hour,
      local.minute + mins,
      local.second,
    );
  }

  void reset() => setState(() {
    movement = Offset.zero;
    startResize = 0;
    endResize = 0;
  });
  void commitMove() {
    final days = (movement.dx / widget.columnWidth).round(),
        mins = minutes(movement.dy);
    reset();
    if (days == 0 && mins == 0) return;
    final start = shift(widget.block.start, days, mins);
    guard(
      context,
      () => moveCalendarBlock(
        context,
        ref,
        widget.block,
        start,
        start.add(widget.block.duration),
      ),
    );
  }

  void commitResize(bool beginning) {
    final delta = minutes(beginning ? startResize : endResize);
    reset();
    if (delta == 0) return;
    guard(
      context,
      () => moveCalendarBlock(
        context,
        ref,
        widget.block,
        beginning
            ? widget.block.start.add(Duration(minutes: delta))
            : widget.block.start,
        beginning
            ? widget.block.end
            : widget.block.end.add(Duration(minutes: delta)),
      ),
    );
  }

  Future<void> menu(Offset position) =>
      showCalendarBlockMenu(context, ref, widget.block, position);

  Widget handle(bool beginning, Color color) => Positioned(
    left: 0,
    right: 0,
    top: beginning ? 0 : null,
    bottom: beginning ? null : 0,
    height: mobile ? 20 : 9,
    child: MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        key: ValueKey(
          'block-resize-${beginning ? 'start' : 'end'}-${widget.block.id}',
        ),
        supportedDevices: const {
          PointerDeviceKind.mouse,
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
        },
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: (_) {
          if (mobile) HapticFeedback.selectionClick();
        },
        onVerticalDragUpdate: (d) => setState(() {
          final maxDelta =
              (widget.block.duration.inMinutes - 5) / 60 * widget.hourHeight;
          if (beginning) {
            startResize = math.min(maxDelta, startResize + d.delta.dy);
          } else {
            endResize = math.max(-maxDelta, endResize + d.delta.dy);
          }
        }),
        onVerticalDragEnd: (_) => commitResize(beginning),
        onVerticalDragCancel: reset,
        child: !mobile || !editing
            ? const SizedBox.expand()
            : Align(
                alignment: beginning
                    ? Alignment.topRight
                    : Alignment.bottomLeft,
                child: Container(
                  key: ValueKey(
                    'block-handle-mark-${beginning ? 'start' : 'end'}-${widget.block.id}',
                  ),
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 2,
                  ),
                  width: mobile ? 26 : 20,
                  height: mobile ? 5 : 2,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: editing ? 1 : .5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(appProvider),
        task = repo.snapshot.task(widget.block.taskId);
    if (task == null) return const SizedBox.shrink();
    final color = Color(repo.snapshot.taskColor(task));
    final running = repo.snapshot.sessions.any(
      (s) => s.taskId == task.id && s.running,
    );
    final canPan = !mobile || editing;
    return LayoutBuilder(
      builder: (context, bounds) {
        final startPixels = minutes(startResize) / 60 * widget.hourHeight;
        final endPixels = minutes(endResize) / 60 * widget.hourHeight;
        final height = math.max(
          22.0,
          bounds.maxHeight + endPixels - startPixels,
        );
        return TapRegion(
          onTapOutside: (_) {
            if (editing && mounted) setState(() => editing = false);
          },
          child: Transform.translate(
            offset: movement + Offset(0, startPixels),
            child: OverflowBox(
              alignment: Alignment.topCenter,
              minHeight: height,
              maxHeight: height,
              child: GestureDetector(
                key: ValueKey('calendar-block-${widget.block.id}'),
                supportedDevices: const {
                  PointerDeviceKind.mouse,
                  PointerDeviceKind.touch,
                  PointerDeviceKind.stylus,
                },
                onTap: () =>
                    openTask(context, task: task, blockId: widget.block.id),
                onSecondaryTapDown: (d) => menu(d.globalPosition),
                onLongPressStart: (_) {
                  HapticFeedback.mediumImpact();
                  setState(() => editing = true);
                },
                onLongPressMoveUpdate: (d) =>
                    setState(() => movement = d.offsetFromOrigin),
                onLongPressEnd: (_) => commitMove(),
                onLongPressCancel: reset,
                onPanUpdate: !canPan
                    ? null
                    : (d) => setState(() => movement += d.delta),
                onPanEnd: !canPan ? null : (_) => commitMove(),
                onPanCancel: !canPan ? null : reset,
                child: Container(
                  height: height,
                  decoration: BoxDecoration(
                    color: Palette.taskSurface(
                      color,
                      subdued: task.done || widget.block.historical,
                      selected: editing,
                    ),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: editing ? color : color.withValues(alpha: .28),
                      width: editing ? 1.5 : .7,
                    ),
                    boxShadow: editing
                        ? [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: .25),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ]
                        : null,
                  ),
                  child: LayoutBuilder(
                    builder: (context, c) {
                      final small = c.maxHeight < 55;
                      final zone = tz.getLocation(
                        repo.snapshot.settings.timezone,
                      );
                      final begin = widget.block.start.add(
                        Duration(minutes: minutes(startResize)),
                      );
                      final finish = widget.block.end.add(
                        Duration(minutes: minutes(endResize)),
                      );
                      return Stack(
                        children: [
                          Positioned(
                            left: 0,
                            top: 6,
                            bottom: 6,
                            width: 3,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: running
                                    ? Palette.pink
                                    : color.withValues(alpha: .8),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              9,
                              small ? 0 : 7,
                              4,
                              0,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        task.title,
                                        maxLines: small ? 1 : 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: task.done
                                              ? Palette.muted
                                              : color,
                                          decoration: task.done
                                              ? TextDecoration.lineThrough
                                              : null,
                                        ),
                                      ),
                                    ),
                                    if (c.maxWidth > 100) ...[
                                      SizedBox(
                                        width: 25,
                                        height: math.min(24, c.maxHeight),
                                        child: IconButton(
                                          padding: EdgeInsets.zero,
                                          tooltip: task.done
                                              ? 'Вернуть в работу'
                                              : 'Завершить',
                                          onPressed: () => guard(
                                            context,
                                            () => repo.status(
                                              task,
                                              task.done
                                                  ? TaskStatus.todo
                                                  : TaskStatus.done,
                                            ),
                                          ),
                                          icon: Icon(
                                            task.done
                                                ? Icons.check_circle_rounded
                                                : Icons.circle_outlined,
                                            size: 16,
                                            color: color,
                                          ),
                                        ),
                                      ),
                                      if (!task.done)
                                        SizedBox(
                                          width: 25,
                                          height: math.min(24, c.maxHeight),
                                          child: IconButton(
                                            key: ValueKey(
                                              'calendar-timer-${widget.block.id}',
                                            ),
                                            padding: EdgeInsets.zero,
                                            tooltip: running
                                                ? 'Остановить'
                                                : 'Начать работу',
                                            onPressed: () => guard(
                                              context,
                                              () => repo.toggleCalendarTimer(
                                                task,
                                              ),
                                            ),
                                            icon: Icon(
                                              running
                                                  ? Icons.pause_rounded
                                                  : Icons.play_arrow_rounded,
                                              size: 19,
                                              color: running
                                                  ? Palette.pink
                                                  : color,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ],
                                ),
                                if (!small && c.maxHeight > 75)
                                  Text(
                                    '${DateFormat('HH:mm').format(tz.TZDateTime.from(begin, zone))} — ${DateFormat('HH:mm').format(tz.TZDateTime.from(finish, zone))}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: color.withValues(alpha: .75),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (!mobile || editing) ...[
                            handle(true, color),
                            handle(false, color),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({
    required this.count,
    required this.columnWidth,
    required this.hourHeight,
    required this.gutter,
  });
  final int count;
  final double columnWidth, hourHeight, gutter;
  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = Palette.border.withValues(alpha: .65)
      ..strokeWidth = .5;
    final half = Paint()
      ..color = Palette.border.withValues(alpha: .25)
      ..strokeWidth = .5;
    for (var h = 0; h <= 24; h++) {
      canvas.drawLine(
        Offset(gutter, h * hourHeight),
        Offset(size.width, h * hourHeight),
        line,
      );
      canvas.drawLine(
        Offset(gutter, (h + .5) * hourHeight),
        Offset(size.width, (h + .5) * hourHeight),
        half,
      );
    }
    for (var d = 0; d <= count; d++) {
      canvas.drawLine(
        Offset(gutter + d * columnWidth, 0),
        Offset(gutter + d * columnWidth, size.height),
        line,
      );
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.count != count || old.columnWidth != columnWidth;
}
