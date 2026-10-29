import '../l10n/strings.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;
import '../domain/models.dart';
import '../domain/workday.dart';
import '../data/repository.dart';
import '../domain/recurrence.dart';
import 'providers.dart';
import 'task_editor.dart';
import 'theme.dart';
import 'birthdays.dart';
import 'month_planning.dart';

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
    this.allowMonth = true,
  });
  final DateTime date, now;
  final CalendarView view;
  final String timezone;
  final ValueChanged<DateTime> onDateChanged;
  final ValueChanged<CalendarView> onViewChanged;
  final bool showDate;
  final bool allowMonth;

  static String dateLabel(DateTime date, CalendarView view) {
    if (view == CalendarView.month) {
      return DateFormat('LLLL y', AppLocale.language).format(date);
    }
    if (view == CalendarView.day) {
      return DateFormat('d MMMM y', AppLocale.language).format(date);
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
    return '${DateFormat(pattern, AppLocale.language).format(first)} — ${DateFormat('d MMM y', AppLocale.language).format(last)}';
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
      final compact = constraints.maxWidth < 460;
      final tiny = constraints.maxWidth < 260;
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
          Builder(
            builder: (context) {
              final controls = Row(
                children: [
                  IconButton(
                    tooltip: tr("Назад"),
                    onPressed: () => navigate(-1),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  IconButton(
                    tooltip: tr("Вперёд"),
                    onPressed: () => navigate(1),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                  if (compact)
                    IconButton(
                      tooltip: tr("Сегодня"),
                      onPressed: () => onDateChanged(now),
                      icon: Icon(
                        Icons.today_outlined,
                        size: 20,
                        color: context.accentColor,
                      ),
                      visualDensity: VisualDensity.compact,
                    )
                  else
                    TextButton(
                      onPressed: () => onDateChanged(now),
                      child: Text(tr("Сегодня")),
                    ),
                  SizedBox(width: tiny ? 0 : 8),
                  if (showDate && !stacked)
                    Expanded(child: label)
                  else
                    const Spacer(),
                  SizedBox(width: tiny ? 0 : 8),
                  PopupMenuButton<CalendarView>(
                    key: const ValueKey('calendar-view-picker'),
                    tooltip: tr("Вид календаря"),
                    initialValue: view,
                    position: PopupMenuPosition.under,
                    offset: const Offset(0, 6),
                    borderRadius: BorderRadius.circular(8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    onSelected: onViewChanged,
                    itemBuilder: (menuContext) => [
                      for (final value in CalendarView.values)
                        if (allowMonth || value != CalendarView.month)
                          PopupMenuItem(
                            value: value,
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 24,
                                  child: value == view
                                      ? Icon(
                                          Icons.check_rounded,
                                          size: 17,
                                          color: menuContext.accentColor,
                                        )
                                      : null,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  value.label,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 10,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (tiny)
                            const Icon(
                              Icons.calendar_view_day_rounded,
                              size: 20,
                            )
                          else
                            Text(
                              view.label,
                              style: TextStyle(
                                fontFamily: 'Inter',
                                color: context.palette.text,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                height: 1.2,
                              ),
                            ),
                          const SizedBox(width: 6),
                          Icon(
                            Icons.expand_more_rounded,
                            size: 16,
                            color: context.palette.muted,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
              return tiny
                  ? SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(width: 260, child: controls),
                    )
                  : controls;
            },
          ),
        ],
      );
    },
  );
}

/// A fresh request reveals the event again, even on the same date.
class CalendarFocus {
  CalendarFocus(this.blockId, this.time);
  final String blockId;
  final DateTime time;
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
    this.onDateChanged,
    this.timeEntryTask,
    this.entries = const [],
    this.onEntriesChanged,
    this.initialTime,
    this.focus,
    this.planningPreview = false,
    this.selectionMinutes,
  });
  final Task? selectedTask;
  final VoidCallback? onPlaced;
  final String projectId;
  final DateTime? initialDate;
  final bool planner;
  final bool showToolbar;
  final ValueChanged<DateTime>? onDateChanged;
  final Task? timeEntryTask;
  final List<TimeBlock> entries;
  final ValueChanged<List<TimeBlock>>? onEntriesChanged;
  final DateTime? initialTime;
  final CalendarFocus? focus;

  /// A local, single-block planning draft. Existing events remain read-only.
  final bool planningPreview;
  final int? selectionMinutes;
  @override
  ConsumerState<CalendarPane> createState() => _CalendarPaneState();
}

enum CalendarDragKind { move, start, end }

class _CalendarDrag {
  _CalendarDrag(this.block, this.kind, this.origin)
    : start = block.start,
      end = block.end;
  final TimeBlock block;
  final CalendarDragKind kind;
  final Offset origin;
  DateTime start, end;
}

class _WorkdayDrag {
  _WorkdayDrag(this.window, this.start, this.origin)
    : original = start ? window.start : window.end,
      value = start ? window.start : window.end;
  final WorkdayWindow window;
  final bool start;
  final Offset origin;
  final DateTime original;
  DateTime value;
}

class _CalendarPaneState extends ConsumerState<CalendarPane>
    with SingleTickerProviderStateMixin {
  late DateTime date;
  final scroll = ScrollController();
  final horizontal = ScrollController();
  final viewportKey = GlobalKey();
  late final Ticker edgeTicker;
  Duration? lastScrollTick;
  Offset? pointer;
  _CalendarDrag? drag;
  _WorkdayDrag? workdayDrag;
  late DateTime interactionFirst;
  double interactionWidth = 0;
  int interactionCount = 0;
  DateTime? selectionStart, selectionEnd, selectionAnchor;
  String? error;
  int expansion = 0;
  double swipeDistance = 0, overscrollDistance = 0;
  CalendarView entryView = CalendarView.day;
  bool get editingDrafts => widget.onEntriesChanged != null;
  bool get enteringTime => editingDrafts && !widget.planningPreview;
  bool get mobile =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;
  tz.Location get _zone =>
      tz.getLocation(ref.read(appProvider).snapshot.settings.timezone);
  DateTime get _clock => _display(ref.read(appProvider).now());

  final pageViewportKey = GlobalKey();
  Timer? pageTimer;
  int pageDirection = 0;
  DateTime? interactionOriginFirst;

  int horizontalEdge() {
    if (widget.planningPreview ||
        pointer == null ||
        (drag == null && workdayDrag == null) ||
        pageViewportKey.currentContext == null) {
      return 0;
    }
    final box =
        pageViewportKey.currentContext!.findRenderObject()! as RenderBox;
    final view = View.of(context);
    final windowBounds =
        Offset.zero & (view.physicalSize / view.devicePixelRatio);
    if (!windowBounds.contains(pointer!)) return 0;
    final local = box.globalToLocal(pointer!);
    // A held drag still belongs to the calendar over sibling widgets. Keep
    // paging active across the sidebar, including items above the day grid.
    final besideCalendar = local.dx < 0 || local.dx > box.size.width;
    if (!besideCalendar && (local.dy < 0 || local.dy > box.size.height)) {
      return 0;
    }
    // The time-label gutter is not a day: the left activation zone starts
    // at the visible day grid, including the gutter when it is on screen.
    final visibleGutter = math.max(
      0.0,
      gutter - (horizontal.hasClients ? horizontal.offset : 0.0),
    );
    final direction = mobile
        ? (local.dx < visibleGutter + 24
              ? -1
              : local.dx > box.size.width - 24
              ? 1
              : 0)
        : (local.dx < 0
              ? -1
              : local.dx > box.size.width
              ? 1
              : 0);
    final boundary = workdayDrag;
    if (boundary != null && direction != 0) {
      if (boundary.start) return 0;
      final earliest = boundary.window.start.add(const Duration(minutes: 5));
      final latest = boundary.window.start.add(const Duration(hours: 25));
      final nextFirst = _date(
        interactionFirst.year,
        interactionFirst.month,
        interactionFirst.day + interactionCount * direction,
      );
      final nextEnd = _date(
        nextFirst.year,
        nextFirst.month,
        nextFirst.day + interactionCount,
      );
      final canScroll =
          horizontal.hasClients &&
          (direction > 0
              ? horizontal.offset < horizontal.position.maxScrollExtent - 1
              : horizontal.offset > 1);
      if (!canScroll &&
          (!latest.isAfter(nextFirst) || !earliest.isBefore(nextEnd))) {
        return 0;
      }
    }
    return direction;
  }

  void updateEdgePage() {
    final direction = horizontalEdge();
    if (direction == pageDirection && pageTimer != null) return;
    pageTimer?.cancel();
    pageTimer = null;
    pageDirection = direction;
    if (direction == 0) return;
    pageTimer = Timer(const Duration(milliseconds: 650), () {
      pageTimer = null;
      if (!mounted || horizontalEdge() != direction) return;
      if (horizontal.hasClients &&
          (direction > 0
              ? horizontal.offset < horizontal.position.maxScrollExtent - 1
              : horizontal.offset > 1)) {
        horizontal.jumpTo(
          (horizontal.offset + direction * interactionWidth).clamp(
            horizontal.position.minScrollExtent,
            horizontal.position.maxScrollExtent,
          ),
        );
        updatePreview();
        updateEdgePage();
        return;
      }
      setState(() {
        date = _date(
          date.year,
          date.month,
          date.day + interactionCount * direction,
        );
        interactionFirst = _date(
          interactionFirst.year,
          interactionFirst.month,
          interactionFirst.day + interactionCount * direction,
        );
      });
      widget.onDateChanged?.call(date);
      HapticFeedback.selectionClick();
      expand();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || pointer == null) return;
        if (horizontal.hasClients) {
          horizontal.jumpTo(
            direction > 0 ? 0 : horizontal.position.maxScrollExtent,
          );
        }
        updatePreview();
        updateEdgePage();
      });
    });
  }

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
  static const gutter = 48.0;
  double hourHeight = 72.0;
  @override
  void initState() {
    super.initState();
    edgeTicker = createTicker(scrollAtEdge);
    date = _midnight(widget.focus?.time ?? widget.initialDate ?? _clock);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      revealTime(widget.focus?.time ?? widget.initialTime ?? _clock);
      expand();
    });
  }

  @override
  void didUpdateWidget(covariant CalendarPane old) {
    super.didUpdateWidget(old);
    final focused = widget.focus != null && widget.focus != old.focus;
    if (focused ||
        (widget.initialDate != null && widget.initialDate != old.initialDate)) {
      date = _midnight(focused ? widget.focus!.time : widget.initialDate!);
      expand();
    }
    if (focused ||
        (widget.initialTime != null && widget.initialTime != old.initialTime)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) revealTime(widget.focus?.time ?? widget.initialTime!);
      });
    }
  }

  void revealTime(DateTime time) {
    final at = _display(time);
    if (scroll.hasClients) {
      final offset = widget.focus == null
          ? (at.hour - 1) * hourHeight
          : (at.hour + at.minute / 60) * hourHeight - 32;
      scroll.jumpTo(offset.clamp(0, scroll.position.maxScrollExtent));
    }
    if (widget.focus != null && horizontal.hasClients) {
      final repo = ref.read(appProvider);
      final view = widget.planner ? repo.plannerView : repo.calendarView;
      final position = horizontal.position;
      final width =
          (position.maxScrollExtent + position.viewportDimension - gutter) /
          view.days;
      horizontal.jumpTo(
        (_dayIndex(at, firstDay(view)) * width).clamp(
          0,
          position.maxScrollExtent,
        ),
      );
    }
  }

  void expand() {
    if (editingDrafts) return;
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
              setState(
                () => error = tr("Не удалось раскрыть повторения: {0}", [e]),
              );
            }
          },
        );
  }

  void changeDate(DateTime value) {
    cancelInteraction();
    setState(() => date = _midnight(value));
    widget.onDateChanged?.call(date);
    expand();
  }

  void swipePage(CalendarView view, double distance, [double velocity = 0]) {
    if (widget.planningPreview) return;
    if (drag != null || workdayDrag != null || selectionAnchor != null) return;
    if (distance.abs() < 60 && !(distance.abs() > 20 && velocity.abs() > 500)) {
      return;
    }
    final direction = distance < 0 ? 1 : -1;
    HapticFeedback.selectionClick();
    changeDate(
      view == CalendarView.month
          ? _date(date.year, date.month + direction, 1)
          : _date(date.year, date.month, date.day + view.days * direction),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && horizontal.hasClients) {
        horizontal.jumpTo(
          direction > 0
              ? horizontal.position.minScrollExtent
              : horizontal.position.maxScrollExtent,
        );
      }
    });
  }

  @override
  void dispose() {
    pageTimer?.cancel();
    edgeTicker.dispose();
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

  Offset contentPosition(Offset global) {
    final viewport =
        viewportKey.currentContext!.findRenderObject()! as RenderBox;
    return viewport.globalToLocal(global) + Offset(0, scroll.offset);
  }

  void beginInteraction(
    Offset global,
    double width,
    int count,
    DateTime first,
  ) {
    pointer = global;
    interactionWidth = width;
    interactionCount = count;
    interactionFirst = first;
    interactionOriginFirst = first;
  }

  void beginDrag(
    TimeBlock block,
    CalendarDragKind kind,
    Offset global,
    double width,
    int count,
    DateTime first,
  ) {
    beginInteraction(global, width, count, first);
    setState(() => drag = _CalendarDrag(block, kind, contentPosition(global)));
  }

  DateTime shift(DateTime value, int days, int minutes) {
    final local = _display(value);
    return tz.TZDateTime(
      _zone,
      local.year,
      local.month,
      local.day + days,
      local.hour,
      local.minute + minutes,
      local.second,
    );
  }

  void updateInteraction(Offset global) {
    if (drag == null && workdayDrag == null && selectionAnchor == null) return;
    pointer = global;
    updatePreview();
    updateEdgeScroll();
    updateEdgePage();
  }

  void updatePreview() {
    final point = contentPosition(pointer!);
    final pageDays = _dayIndex(
      interactionFirst,
      interactionOriginFirst ?? interactionFirst,
    );
    final boundary = workdayDrag;
    if (boundary != null) {
      final minutes =
          ((point.dy - boundary.origin.dy) / hourHeight * 60 / 5).round() * 5;
      final day = boundary.window.date;
      int column(double x) => ((x - gutter) / interactionWidth).floor().clamp(
        0,
        interactionCount - 1,
      );
      final days = boundary.start
          ? 0
          : pageDays + column(point.dx) - column(boundary.origin.dx);
      var minimum = boundary.start
          ? day
          : boundary.window.start.add(const Duration(minutes: 5));
      var maximum = boundary.start
          ? boundary.window.end.subtract(const Duration(minutes: 5))
          : boundary.window.start.add(const Duration(hours: 25));
      final dateLimit = boundary.start
          ? _date(
              day.year,
              day.month,
              day.day + 1,
            ).subtract(const Duration(minutes: 5))
          : _date(day.year, day.month, day.day + 2);
      if (maximum.isAfter(dateLimit)) maximum = dateLimit;
      var value = shift(boundary.original, days, minutes);
      if (value.isBefore(minimum)) value = minimum;
      if (value.isAfter(maximum)) value = maximum;
      if (value != boundary.value) setState(() => boundary.value = value);
      return;
    }
    final active = drag;
    if (active != null) {
      int column(double x) => ((x - gutter) / interactionWidth).floor().clamp(
        0,
        interactionCount - 1,
      );
      final days = widget.planningPreview
          ? 0
          : pageDays + column(point.dx) - column(active.origin.dx);
      final minutes =
          ((point.dy - active.origin.dy) / hourHeight * 60 / 5).round() * 5;
      var start = active.block.start, end = active.block.end;
      switch (active.kind) {
        case CalendarDragKind.move:
          start = shift(start, days, minutes);
          end = start.add(active.block.duration);
        case CalendarDragKind.start:
          start = shift(start, days, minutes);
          final latest = end.subtract(const Duration(minutes: 5));
          if (start.isAfter(latest)) start = latest;
        case CalendarDragKind.end:
          end = shift(end, days, minutes);
          final earliest = start.add(const Duration(minutes: 5));
          if (end.isBefore(earliest)) end = earliest;
      }
      if (widget.planningPreview && active.kind != CalendarDragKind.end) {
        // This editor chooses a time within the date selected in the month.
        // Keep the start on that date; the duration may extend past midnight.
        final lastStart = _date(
          interactionFirst.year,
          interactionFirst.month,
          interactionFirst.day,
          23,
          55,
        );
        if (start.isBefore(interactionFirst)) start = interactionFirst;
        if (start.isAfter(lastStart)) start = lastStart;
        if (active.kind == CalendarDragKind.move) {
          end = start.add(active.block.duration);
        }
      }
      if (start != active.start || end != active.end) {
        setState(() {
          active.start = start;
          active.end = end;
        });
      }
    } else if (selectionAnchor != null) {
      final next = at(
        point,
        interactionWidth,
        interactionCount,
        interactionFirst,
      );
      final anchor = selectionAnchor!;
      final start = next.isBefore(anchor) ? next : anchor;
      final end = next.isAfter(anchor)
          ? next
          : anchor.add(const Duration(minutes: 5));
      if (start != selectionStart || end != selectionEnd) {
        setState(() {
          selectionStart = start;
          selectionEnd = end;
        });
      }
    }
  }

  double edgeVelocity() {
    if (pointer == null ||
        !scroll.hasClients ||
        viewportKey.currentContext == null) {
      return 0;
    }
    final viewport =
        viewportKey.currentContext!.findRenderObject()! as RenderBox;
    final local = viewport.globalToLocal(pointer!);
    final zone = viewport.size.height * .2;
    if (zone <= 0 || local.dx < 0 || local.dx > viewport.size.width) return 0;
    final pressure = local.dy < zone
        ? -(1 - local.dy / zone).clamp(0.0, 1.0)
        : local.dy > viewport.size.height - zone
        ? ((local.dy - (viewport.size.height - zone)) / zone).clamp(0.0, 1.0)
        : 0.0;
    if (pressure < 0 && scroll.offset <= scroll.position.minScrollExtent ||
        pressure > 0 && scroll.offset >= scroll.position.maxScrollExtent) {
      return 0;
    }
    return pressure * 600;
  }

  void updateEdgeScroll() {
    if (edgeVelocity() == 0) {
      edgeTicker.stop();
      lastScrollTick = null;
    } else if (!edgeTicker.isActive) {
      lastScrollTick = null;
      edgeTicker.start();
    }
  }

  void scrollAtEdge(Duration elapsed) {
    final seconds = lastScrollTick == null
        ? 0.0
        : ((elapsed - lastScrollTick!).inMicroseconds /
                  Duration.microsecondsPerSecond)
              .clamp(0.0, .05);
    lastScrollTick = elapsed;
    final velocity = edgeVelocity();
    if (velocity == 0) {
      updateEdgeScroll();
      return;
    }
    scroll.jumpTo(
      (scroll.offset + velocity * seconds).clamp(
        scroll.position.minScrollExtent,
        scroll.position.maxScrollExtent,
      ),
    );
    updatePreview();
    updateEdgeScroll();
  }

  void cancelInteraction() {
    pageTimer?.cancel();
    pageTimer = null;
    pageDirection = 0;
    interactionOriginFirst = null;
    edgeTicker.stop();
    lastScrollTick = null;
    setState(() {
      pointer = null;
      drag = null;
      workdayDrag = null;
      selectionStart = null;
      selectionEnd = null;
      selectionAnchor = null;
    });
  }

  void finishDrag() {
    final active = drag;
    cancelInteraction();
    if (active == null ||
        (active.start == active.block.start &&
            active.end == active.block.end)) {
      return;
    }
    if (editingDrafts) {
      widget.onEntriesChanged!([
        for (final block in widget.entries)
          if (block.id == active.block.id)
            TimeBlock(
              block.entity.change({
                'start': wireTime(active.start),
                'end': wireTime(active.end),
              }),
            )
          else
            block,
      ]);
      return;
    }
    guard(
      context,
      () => moveCalendarBlock(
        context,
        ref,
        active.block,
        active.start,
        active.end,
      ),
    );
  }

  Future<void> place(DateTime start, DateTime end) async {
    if (editingDrafts) {
      widget.onEntriesChanged!([
        if (!widget.planningPreview) ...widget.entries,
        TimeBlock(
          TimeBlock.create(
            ref.read(appProvider).newId(),
            widget.timeEntryTask!.id,
            start,
            end,
            timezone: _zone.name,
            reminders: const [],
          ),
        ),
      ]);
      return;
    }
    if (widget.selectedTask != null) {
      await guard(context, () async {
        await ref.read(appProvider).schedule(widget.selectedTask!, start, end);
        widget.onPlaced?.call();
      });
    } else {
      await openTask(context, start: start, end: end);
    }
  }

  Future<void> placeInMonth(DateTime day) async {
    final repo = ref.read(appProvider);
    final task = widget.selectedTask;
    if (task == null) {
      final start = _date(day.year, day.month, day.day, 9);
      await place(
        start,
        start.add(Duration(minutes: repo.snapshot.settings.defaultMinutes)),
      );
      return;
    }
    final range = await chooseMonthPlan(context, task: task, day: day);
    if (!mounted || range == null) return;
    await guard(context, () async {
      final current = repo.snapshot.task(task.id);
      if (current == null) throw StateError(tr("Задача уже удалена"));
      await repo.schedule(current, range.start, range.end);
      if (mounted) widget.onPlaced?.call();
    });
  }

  void layoutHours(double height, double zoom) {
    final next = math.max(height / 24, 72.0 * zoom);
    if ((next - hourHeight).abs() < .01) return;
    final anchor = scroll.hasClients
        ? (scroll.offset + height / 2) / hourHeight
        : null;
    hourHeight = next;
    if (anchor != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !scroll.hasClients) return;
        scroll.jumpTo(
          (anchor * hourHeight - height / 2).clamp(
            0,
            scroll.position.maxScrollExtent,
          ),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(appProvider),
        view = editingDrafts
            ? entryView
            : widget.planner
            ? repo.plannerView
            : repo.calendarView,
        first = firstDay(view);
    final blocks = enteringTime
        ? widget.entries
        : repo.snapshot.blocks.where((b) {
            final t = repo.snapshot.task(b.taskId);
            return t != null &&
                !(t.isBirthday && t.done) &&
                (!widget.planner || !t.isBirthday) &&
                (t.isBirthday ||
                    widget.projectId.isEmpty ||
                    t.projectId == widget.projectId);
          }).toList();
    if (widget.planningPreview) blocks.addAll(widget.entries);
    return GestureDetector(
      key: const ValueKey('calendar-swipe'),
      supportedDevices: const {
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
      },
      onHorizontalDragStart: !mobile || widget.planningPreview
          ? null
          : (_) => swipeDistance = 0,
      onHorizontalDragUpdate: !mobile || widget.planningPreview
          ? null
          : (d) => swipeDistance += d.delta.dx,
      onHorizontalDragEnd: !mobile || widget.planningPreview
          ? null
          : (d) => swipePage(view, swipeDistance, d.primaryVelocity ?? 0),
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (!mobile ||
              notification.metrics.axis != Axis.horizontal ||
              drag != null ||
              workdayDrag != null ||
              selectionAnchor != null) {
            return false;
          }
          if (notification is ScrollStartNotification) overscrollDistance = 0;
          if (notification is OverscrollNotification &&
              notification.dragDetails != null) {
            overscrollDistance -= notification.overscroll;
          }
          if (notification is ScrollEndNotification &&
              overscrollDistance != 0) {
            final distance = overscrollDistance;
            overscrollDistance = 0;
            // Notifications arrive during layout; page changes wait for its end.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) swipePage(view, distance);
            });
          }
          return false;
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: context.palette.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: context.palette.border, width: .6),
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
                    allowMonth: !editingDrafts,
                    onDateChanged: changeDate,
                    onViewChanged: (value) {
                      if (editingDrafts) {
                        setState(() => entryView = value);
                        return;
                      }
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
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
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
                            key: pageViewportKey,
                            controller: horizontal,
                            child: SingleChildScrollView(
                              controller: horizontal,
                              physics: const ClampingScrollPhysics(),
                              scrollDirection: Axis.horizontal,
                              child: SizedBox(
                                width: fullWidth,
                                child: Column(
                                  children: [
                                    if (!widget.planningPreview &&
                                        !(widget.planner &&
                                            mobile &&
                                            view == CalendarView.day &&
                                            constraints.maxHeight < 160))
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
                                    if (!widget.planningPreview &&
                                        blocks.any(
                                          (b) =>
                                              repo.snapshot
                                                      .task(b.taskId)
                                                      ?.isBirthday ==
                                                  true &&
                                              b.start.isBefore(
                                                _date(
                                                  first.year,
                                                  first.month,
                                                  first.day + count,
                                                ),
                                              ) &&
                                              b.end.isAfter(first),
                                        ))
                                      birthdayRow(
                                        repo,
                                        blocks,
                                        first,
                                        width,
                                        count,
                                      ),
                                    const Divider(),
                                    Expanded(
                                      child: LayoutBuilder(
                                        builder: (context, viewport) {
                                          layoutHours(
                                            viewport.maxHeight,
                                            repo.calendarZoom,
                                          );
                                          return SizedBox(
                                            key: viewportKey,
                                            child: Scrollbar(
                                              controller: scroll,
                                              child: SingleChildScrollView(
                                                key: const ValueKey(
                                                  'calendar-scroll',
                                                ),
                                                controller: scroll,
                                                child: SizedBox(
                                                  height: 24 * hourHeight,
                                                  width: fullWidth,
                                                  child: CalendarGestureSurface(
                                                    key: const ValueKey(
                                                      'calendar-grid-gestures',
                                                    ),
                                                    allowTouchTap:
                                                        widget.planningPreview,
                                                    onTap: (global) {
                                                      final position =
                                                          contentPosition(
                                                            global,
                                                          );
                                                      if (position.dx <
                                                          gutter) {
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
                                                            minutes:
                                                                widget
                                                                    .selectionMinutes ??
                                                                repo
                                                                    .snapshot
                                                                    .settings
                                                                    .defaultMinutes,
                                                          ),
                                                        ),
                                                      );
                                                    },
                                                    onStart: (global) {
                                                      final position =
                                                          contentPosition(
                                                            global,
                                                          );
                                                      if (position.dx <
                                                          gutter) {
                                                        return;
                                                      }
                                                      beginInteraction(
                                                        global,
                                                        width,
                                                        count,
                                                        first,
                                                      );
                                                      setState(() {
                                                        selectionAnchor = at(
                                                          position,
                                                          width,
                                                          count,
                                                          first,
                                                        );
                                                        selectionStart =
                                                            selectionAnchor;
                                                        selectionEnd =
                                                            selectionStart!.add(
                                                              Duration(
                                                                minutes:
                                                                    widget
                                                                        .selectionMinutes ??
                                                                    repo
                                                                        .snapshot
                                                                        .settings
                                                                        .defaultMinutes,
                                                              ),
                                                            );
                                                      });
                                                    },
                                                    onUpdate: updateInteraction,
                                                    onCancel: () {
                                                      if (drag == null &&
                                                          workdayDrag == null) {
                                                        cancelInteraction();
                                                      }
                                                    },
                                                    onEnd: () {
                                                      final start =
                                                              selectionStart,
                                                          end = selectionEnd;
                                                      cancelInteraction();
                                                      if (start != null &&
                                                          end != null) {
                                                        place(start, end);
                                                      }
                                                    },
                                                    child: Stack(
                                                      clipBehavior:
                                                          Clip.hardEdge,
                                                      children: [
                                                        Positioned.fill(
                                                          child: CustomPaint(
                                                            painter: _GridPainter(
                                                              border: context
                                                                  .palette
                                                                  .border,
                                                              count: count,
                                                              columnWidth:
                                                                  width,
                                                              hourHeight:
                                                                  hourHeight,
                                                              gutter: gutter,
                                                            ),
                                                          ),
                                                        ),
                                                        for (
                                                          var h = 0;
                                                          h < 24;
                                                          h += hourHeight < 20
                                                              ? 2
                                                              : 1
                                                        )
                                                          Positioned(
                                                            left: 8,
                                                            top:
                                                                h * hourHeight +
                                                                5,
                                                            child: Text(
                                                              '${h.toString().padLeft(2, '0')}:00',
                                                              style:
                                                                  const TextStyle(
                                                                    fontSize:
                                                                        10,
                                                                    color: Palette
                                                                        .muted,
                                                                  ),
                                                            ),
                                                          ),
                                                        if (enteringTime)
                                                          ...planGuides(
                                                            repo,
                                                            first,
                                                            width,
                                                            count,
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
                                                            gutter +
                                                                width * day,
                                                            width,
                                                            first,
                                                            count,
                                                          ),
                                                        if (drag != null &&
                                                            interactionOriginFirst !=
                                                                first)
                                                          for (
                                                            var i = 0;
                                                            i < interactionCount;
                                                            i++
                                                          )
                                                            ..._dayBlocks(
                                                              repo,
                                                              [drag!.block],
                                                              _date(
                                                                interactionOriginFirst!
                                                                    .year,
                                                                interactionOriginFirst!
                                                                    .month,
                                                                interactionOriginFirst!
                                                                        .day +
                                                                    i,
                                                              ),
                                                              -10000,
                                                              width,
                                                              first,
                                                              count,
                                                            ),
                                                        if (!editingDrafts)
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
                                                              gutter +
                                                                  width * day,
                                                            ),
                                                        if (!_clock.isBefore(
                                                              first,
                                                            ) &&
                                                            _clock.isBefore(
                                                              _date(
                                                                first.year,
                                                                first.month,
                                                                first.day +
                                                                    count,
                                                              ),
                                                            ))
                                                          Positioned(
                                                            left:
                                                                gutter +
                                                                _dayIndex(
                                                                      _clock,
                                                                      first,
                                                                    ) *
                                                                    width,
                                                            top:
                                                                (_clock.hour +
                                                                    _clock.minute /
                                                                        60) *
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
                                                                    decoration: const BoxDecoration(
                                                                      color: Palette
                                                                          .pink,
                                                                      shape: BoxShape
                                                                          .circle,
                                                                    ),
                                                                  ),
                                                                  Expanded(
                                                                    child: Container(
                                                                      height: 1,
                                                                      color: Palette
                                                                          .pink
                                                                          .withValues(
                                                                            alpha:
                                                                                .7,
                                                                          ),
                                                                    ),
                                                                  ),
                                                                ],
                                                              ),
                                                            ),
                                                          ),
                                                        if (drag != null ||
                                                            selectionStart !=
                                                                null)
                                                          ...previewSegments(
                                                            repo,
                                                            first,
                                                            width,
                                                            count,
                                                          ),
                                                        if (!editingDrafts)
                                                          ...workdayLines(
                                                            repo,
                                                            blocks,
                                                            first,
                                                            width,
                                                            count,
                                                          ),
                                                        if (drag != null ||
                                                            workdayDrag !=
                                                                null ||
                                                            selectionStart !=
                                                                null)
                                                          ...timeGuide(),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          );
                                        },
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
        ),
      ),
    );
  }

  void finishWorkdayDrag() {
    final active = workdayDrag;
    cancelInteraction();
    if (active == null || active.value == active.original) return;
    guard(
      context,
      () => ref
          .read(appProvider)
          .setWorkdayBoundary(
            active.window.date,
            start: active.start,
            value: active.value,
          ),
    );
  }

  Iterable<Widget> workdayLines(
    Repository repo,
    List<TimeBlock> blocks,
    DateTime first,
    double width,
    int count,
  ) sync* {
    final schedule = WorkdaySchedule(repo.snapshot);
    final days = {
      for (var i = -1; i < count; i++)
        _date(first.year, first.month, first.day + i),
      if (workdayDrag != null) workdayDrag!.window.date,
    };
    for (final day in days) {
      final window = schedule.forDate(day);
      if (window == null) continue;
      for (final start in [true, false]) {
        final moving =
            workdayDrag?.window.date == day && workdayDrag?.start == start;
        final value = _display(
          moving
              ? workdayDrag!.value
              : start
              ? window.start
              : window.end,
        );
        final nextDay = dayKey(value) != dayKey(day);
        var index = _dayIndex(_midnight(value), first);
        final atMidnight =
            !start && value.hour == 0 && value.minute == 0 && index > 0;
        if (atMidnight) index--;
        if ((index < 0 || index >= count) && !moving) continue;
        final displayDay = _date(first.year, first.month, first.day + index);
        final y = atMidnight
            ? 24 * hourHeight
            : (value.hour + value.minute / 60) * hourHeight;
        final color = moving ? context.accentColor : context.palette.muted;
        final title = start
            ? tr("Начало дня")
            : nextDay
            ? tr("Конец {0}", [
                DateFormat('d MMM', AppLocale.language).format(day),
              ])
            : tr("Конец дня");
        final markerTop = (start ? y + 3 : y - 27).clamp(
          0.0,
          24 * hourHeight - 24,
        );
        // Keep event completion/timer buttons clickable even when several
        // short events begin on this boundary.
        final nearHeaders = blocks.where((block) {
          if (repo.snapshot.task(block.taskId)?.isBirthday == true) {
            return false;
          }
          final begin = _display(block.start);
          if (dayKey(begin) != dayKey(displayDay)) return false;
          final top = (begin.hour + begin.minute / 60) * hourHeight;
          return top < markerTop + 24 && top + 32 > markerTop;
        }).length;
        final time = atMidnight
            ? '24:00'
            : '${DateFormat('HH:mm').format(value)}${nextDay ? ' +1' : ''}';
        yield Positioned(
          left: gutter + index * width + 3,
          top: y,
          width: width - 6,
          height: 1,
          child: IgnorePointer(
            child: CustomPaint(
              painter: _WorkdayLinePainter(
                color.withValues(alpha: moving ? .8 : .5),
              ),
            ),
          ),
        );
        yield Positioned(
          key: ValueKey('workday-marker-${dayKey(day)}-$start'),
          left: gutter + index * width + 4,
          top: markerTop,
          width: width - 8,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Tooltip(
              message: tr("{0} · {1}\nПотяните метку, чтобы изменить время.", [
                title,
                time,
              ]),
              triggerMode: TooltipTriggerMode.manual,
              waitDuration: const Duration(milliseconds: 350),
              child: MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: CalendarGestureSurface(
                  key: ValueKey(
                    'workday-${start ? 'start' : 'end'}-${dayKey(day)}',
                  ),
                  // Consume taps so they cannot create an event underneath.
                  allowTouchTap: true,
                  onTap: (_) {},
                  onStart: (global) {
                    beginInteraction(global, width, count, first);
                    setState(
                      () => workdayDrag = _WorkdayDrag(
                        window,
                        start,
                        contentPosition(global),
                      ),
                    );
                    updateEdgeScroll();
                  },
                  onUpdate: updateInteraction,
                  onEnd: finishWorkdayDrag,
                  onCancel: () {
                    if (workdayDrag != null) cancelInteraction();
                  },
                  child: Semantics(
                    label: '$title, $time',
                    hint: tr("Перетащите, чтобы изменить время"),
                    child: Container(
                      width: nearHeaders > 1 ? 18 : 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: context.palette.surface,
                        border: Border.all(color: color.withValues(alpha: .55)),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Icon(
                        start
                            ? Icons.wb_sunny_outlined
                            : Icons.bedtime_outlined,
                        size: 12,
                        color: color,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }
  }

  List<Widget> timeGuide() {
    final active = drag;
    final value = _display(
      workdayDrag?.value ??
          (active == null
              ? at(
                  contentPosition(pointer!),
                  interactionWidth,
                  interactionCount,
                  interactionFirst,
                )
              : active.kind == CalendarDragKind.end
              ? active.end
              : active.start),
    );
    final endOfWorkday =
        workdayDrag != null &&
        !workdayDrag!.start &&
        value.hour == 0 &&
        value.minute == 0 &&
        _dayIndex(_midnight(value), interactionFirst) > 0;
    final y = endOfWorkday
        ? 24 * hourHeight
        : (value.hour + value.minute / 60) * hourHeight;
    final left = horizontal.hasClients ? horizontal.offset : 0.0;
    return [
      Positioned(
        key: const ValueKey('calendar-time-guide'),
        left: left + gutter - 4,
        right: 0,
        top: y,
        child: IgnorePointer(
          child: SizedBox(
            height: 1,
            child: ColoredBox(color: context.accentColor),
          ),
        ),
      ),
      Positioned(
        left: left + 2,
        top: (y - 10).clamp(0, 24 * hourHeight - 22),
        width: gutter - 6,
        child: IgnorePointer(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 3),
            decoration: BoxDecoration(
              color: context.accentColor,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              endOfWorkday ? '24:00' : DateFormat('HH:mm').format(value),
              key: const ValueKey('calendar-time-label'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                height: 1.3,
                fontWeight: FontWeight.w600,
                color: context.palette.background,
              ),
            ),
          ),
        ),
      ),
    ];
  }

  Widget _dayHeader(DateTime day) {
    final today = _midnight(day) == _midnight(_clock);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          DateFormat('EEE', AppLocale.language).format(day),
          style: TextStyle(
            fontSize: 11,
            color: today ? context.accentColor : context.palette.muted,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: today ? context.accentColor : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            '${day.day}',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: today ? context.palette.background : context.palette.text,
            ),
          ),
        ),
      ],
    );
  }

  Widget birthdayRow(
    Repository repo,
    List<TimeBlock> blocks,
    DateTime first,
    double width,
    int count,
  ) {
    final days = [
      for (var i = 0; i < count; i++)
        blocks
            .where(
              (b) =>
                  repo.snapshot.task(b.taskId)?.isBirthday == true &&
                  _midnight(b.start) ==
                      _date(first.year, first.month, first.day + i),
            )
            .toList(),
    ];
    final rows = days.fold(
      0,
      (value, blocks) => math.max(value, blocks.length),
    );
    return SizedBox(
      key: const ValueKey('birthday-calendar-row'),
      height: math.min(3, rows) * 39.0 + 6,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: gutter,
            height: 34,
            child: Icon(
              Icons.cake_outlined,
              size: 17,
              color: context.palette.accent(birthdayColor),
            ),
          ),
          for (final items in days)
            SizedBox(
              width: width,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                children: [
                  for (final block in items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: BirthdayChip(
                        task: repo.snapshot.task(block.taskId)!,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _dayBlocks(
    Repository repo,
    List<TimeBlock> blocks,
    DateTime day,
    double left,
    double width,
    DateTime first,
    int count,
  ) {
    final end = _date(day.year, day.month, day.day + 1);
    final list =
        blocks
            .where(
              (b) =>
                  repo.snapshot.task(b.taskId)?.isBirthday != true &&
                  b.start.isBefore(end) &&
                  b.end.isAfter(day),
            )
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
        child: Opacity(
          // This segment owns the active gesture even when its preview moves
          // off screen or continues into another day.
          opacity: drag?.block.id == b.id ? 0 : 1,
          child:
              widget.planningPreview &&
                  !widget.entries.any((entry) => entry.id == b.id)
              ? IgnorePointer(
                  child: Container(
                    key: ValueKey('planning-busy-${b.id}'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: context.palette.raised,
                      border: Border(
                        left: BorderSide(
                          color: Color(
                            repo.snapshot.taskColor(
                              repo.snapshot.task(b.taskId)!,
                            ),
                          ).withValues(alpha: .55),
                          width: 2,
                        ),
                      ),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${DateFormat('HH:mm').format(start)} · ${repo.snapshot.task(b.taskId)!.title}',
                      maxLines: height > 48 ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.palette.muted,
                        fontSize: 11,
                      ),
                    ),
                  ),
                )
              : CalendarBlock(
                  block: b,
                  day: day,
                  highlighted: b.id == widget.focus?.blockId,
                  planning: widget.planningPreview,
                  showMenuButton:
                      widget.planner &&
                      mobile &&
                      !enteringTime &&
                      !widget.planningPreview,
                  onDragStart: (kind, global) =>
                      beginDrag(b, kind, global, width, count, first),
                  onDragUpdate: updateInteraction,
                  onDragEnd: finishDrag,
                  onDragCancel: cancelInteraction,
                  onDelete: enteringTime
                      ? () => widget.onEntriesChanged!(
                          widget.entries
                              .where((entry) => entry.id != b.id)
                              .toList(),
                        )
                      : null,
                ),
        ),
      );
    }).toList();
  }

  List<Widget> previewSegments(
    Repository repo,
    DateTime first,
    double width,
    int count,
  ) {
    final start = drag?.start ?? selectionStart!;
    final end = drag?.end ?? selectionEnd!;
    final task = drag == null
        ? widget.timeEntryTask ?? widget.selectedTask
        : repo.snapshot.task(drag!.block.taskId);
    final color = enteringTime
        ? context.palette.pink
        : task == null
        ? context.accentColor
        : context.palette.accent(Color(repo.snapshot.taskColor(task)));
    return [
      for (var index = 0; index < count; index++)
        if (start.isBefore(
              _date(first.year, first.month, first.day + index + 1),
            ) &&
            end.isAfter(_date(first.year, first.month, first.day + index)))
          previewSegment(
            start,
            end,
            _date(first.year, first.month, first.day + index),
            gutter + width * index + 12,
            width - 21,
            task?.title ?? tr("Новая задача"),
            color,
          ),
    ];
  }

  List<Widget> planGuides(
    Repository repo,
    DateTime first,
    double width,
    int count,
  ) {
    final result = <Widget>[];
    for (var day = 0; day < count; day++) {
      final from = _date(first.year, first.month, first.day + day);
      final to = _date(first.year, first.month, first.day + day + 1);
      for (final block in repo.snapshot.taskBlocks(widget.timeEntryTask!.id)) {
        if (!block.start.isBefore(to) || !block.end.isAfter(from)) continue;
        final start = block.start.isBefore(from) ? from : _display(block.start);
        final end = block.end.isAfter(to) ? to : _display(block.end);
        result.add(
          Positioned(
            key: ValueKey('time-plan-${block.id}-${dayKey(from)}'),
            left: gutter + day * width + 8,
            width: width - 14,
            top: (start.hour + start.minute / 60) * hourHeight,
            height: math.max(
              22,
              end.difference(start).inMinutes * hourHeight / 60,
            ),
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: context.accentColor.withValues(alpha: .65),
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.topRight,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Text(
                  tr("{0} — {1} · план", [
                    DateFormat('HH:mm').format(start),
                    end == to ? '24:00' : DateFormat('HH:mm').format(end),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: context.accentColor),
                ),
              ),
            ),
          ),
        );
      }
    }
    return result;
  }

  Widget previewSegment(
    DateTime start,
    DateTime end,
    DateTime day,
    double left,
    double width,
    String title,
    Color color,
  ) {
    final dayEnd = _date(day.year, day.month, day.day + 1);
    final begin = start.isBefore(day) ? day : _display(start);
    final finish = end.isAfter(dayEnd) ? dayEnd : _display(end);
    final height = math.max(
      22.0,
      finish.difference(begin).inMinutes / 60 * hourHeight - 3,
    );
    return Positioned(
      key: ValueKey('calendar-preview-${dayKey(day)}'),
      left: left,
      top: (begin.hour + begin.minute / 60) * hourHeight,
      width: width,
      height: height,
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          builder: (_, value, child) => Opacity(
            opacity: value,
            child: Transform.translate(
              offset: Offset(0, -8 * (1 - value)),
              child: child,
            ),
          ),
          child: Container(
            decoration: BoxDecoration(
              color: context.palette.taskSurface(color, selected: true),
              border: Border.all(color: color, width: 1.5),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .2),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            padding: EdgeInsets.symmetric(
              horizontal: 9,
              vertical: height < 40 ? 0 : 7,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (height > 55)
                  Text(
                    '${DateFormat('HH:mm').format(begin)} — ${finish == dayEnd ? '24:00' : DateFormat('HH:mm').format(finish)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: color, fontSize: 10),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
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
                  '${task?.title ?? tr("Работа")} · ${formatDuration(finish.difference(start))}',
              child: GestureDetector(
                onTap: task == null
                    ? null
                    : () => editSession(context, task, session: s),
                child: Container(
                  decoration: BoxDecoration(
                    color: s.running
                        ? context.palette.pink
                        : context.palette.pink.withValues(alpha: .55),
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
                ..sort((a, b) {
                  final aBirthday = repo.snapshot.task(a.taskId)!.isBirthday;
                  final bBirthday = repo.snapshot.task(b.taskId)!.isBirthday;
                  return aBirthday == bBirthday
                      ? a.start.compareTo(b.start)
                      : aBirthday
                      ? -1
                      : 1;
                });
          final capacity = ((math.max(105, c.maxHeight / 6) - 38) / 30)
              .floor()
              .clamp(1, 3);
          return InkWell(
            key: ValueKey('calendar-month-day-${dayKey(day)}'),
            onTap: () => placeInMonth(day),
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  right: BorderSide(color: context.palette.border, width: .5),
                  bottom: BorderSide(color: context.palette.border, width: .5),
                ),
                color: _midnight(day) == _midnight(_clock)
                    ? context.accentColor.withValues(alpha: .04)
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
                          ? context.palette.text
                          : context.palette.muted.withValues(alpha: .4),
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 5),
                  for (final b in items.take(capacity))
                    Builder(
                      builder: (_) {
                        final task = repo.snapshot.task(b.taskId)!;
                        if (task.isBirthday) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: BirthdayChip(task: task, compact: true),
                          );
                        }
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
                              color: context.palette.taskSurface(
                                context.palette.accent(
                                  Color(repo.snapshot.taskColor(task)),
                                ),
                                subdued: task.done || b.historical,
                              ),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    task.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 10,
                                      decoration: task.done
                                          ? TextDecoration.lineThrough
                                          : null,
                                      color: context.palette.accent(
                                        Color(repo.snapshot.taskColor(task)),
                                      ),
                                    ),
                                  ),
                                ),
                                if (widget.planner && mobile)
                                  SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CalendarEventMenuButton(
                                      block: b,
                                      includeQuickActions: true,
                                      color: context.palette.accent(
                                        Color(repo.snapshot.taskColor(task)),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  if (items.length > capacity)
                    Text(
                      '+${items.length - capacity}',
                      style: TextStyle(
                        fontSize: 10,
                        color: context.palette.muted,
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
    this.allowTouchTap = false,
  });
  final ValueChanged<Offset> onTap, onStart, onUpdate;
  final VoidCallback onEnd, onCancel;
  final Widget child;
  final bool allowTouchTap;
  @override
  Widget build(BuildContext context) => Listener(
    onPointerCancel: (_) => onCancel(),
    child: GestureDetector(
      supportedDevices: const {
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
      },
      behavior: HitTestBehavior.opaque,
      onTapUp: allowTouchTap ? (d) => onTap(d.globalPosition) : null,
      onLongPressStart: (d) {
        HapticFeedback.mediumImpact();
        onStart(d.globalPosition);
      },
      onLongPressMoveUpdate: (d) => onUpdate(d.globalPosition),
      onLongPressEnd: (_) => onEnd(),
      onLongPressCancel: onCancel,
      child: GestureDetector(
        // Two-finger pan/zoom belongs to the scroll view. A pressed trackpad
        // click is delivered as a mouse pointer and can still select a range.
        supportedDevices: const {PointerDeviceKind.mouse},
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => onTap(d.globalPosition),
        dragStartBehavior: DragStartBehavior.down,
        onPanStart: (d) => onStart(d.globalPosition),
        onPanUpdate: (d) => onUpdate(d.globalPosition),
        onPanEnd: (_) => onEnd(),
        onPanCancel: onCancel,
        child: child,
      ),
    ),
  );
}

Future<void> showCalendarBlockMenu(
  BuildContext context,
  WidgetRef ref,
  TimeBlock block,
  Offset position, {
  bool includeQuickActions = false,
}) async {
  final task = ref.read(appProvider).snapshot.task(block.taskId);
  if (task == null) return;
  final choice = await showMenu<String>(
    context: context,
    position: menuPosition(context, position),
    items: [
      if (includeQuickActions) ...[
        PopupMenuItem(
          value: 'complete',
          child: Text(task.done ? tr("Вернуть в работу") : tr("Завершить")),
        ),
        if (!task.done)
          PopupMenuItem(
            value: 'timer',
            child: Text(
              ref
                      .read(appProvider)
                      .snapshot
                      .sessions
                      .any(
                        (s) => s.taskId == task.id && s.running && !s.discarded,
                      )
                  ? tr("Остановить")
                  : tr("Начать работу"),
            ),
          ),
        const PopupMenuDivider(),
      ],
      PopupMenuItem(value: 'task', child: Text(tr("Открыть задачу"))),
      PopupMenuItem(
        value: 'edit',
        child: Text(tr("Изменить время и напоминания")),
      ),
      PopupMenuItem(value: 'unschedule', child: Text(tr("Убрать из плана"))),
      PopupMenuItem(value: 'add', child: Text(tr("Добавить блок"))),
      PopupMenuItem(value: 'split', child: Text(tr("Разделить блок"))),
      if (!task.done)
        PopupMenuItem(
          value: 'review',
          child: Text(tr("Готово → создать проверку")),
        ),
      const PopupMenuDivider(),
      PopupMenuItem(value: 'delete', child: Text(tr("Удалить задачу"))),
    ],
  );
  if (choice == null || !context.mounted) return;
  await guard(context, () async {
    final repo = ref.read(appProvider);
    switch (choice) {
      case 'complete':
        await repo.status(task, task.done ? TaskStatus.todo : TaskStatus.done);
      case 'timer':
        await repo.toggleCalendarTimer(task);
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

class CalendarEventMenuButton extends ConsumerWidget {
  const CalendarEventMenuButton({
    super.key,
    required this.block,
    required this.color,
    this.includeQuickActions = false,
  });
  final TimeBlock block;
  final Color color;
  final bool includeQuickActions;

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
    key: ValueKey('calendar-menu-${block.id}'),
    tooltip: tr("Действия события"),
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(),
    visualDensity: VisualDensity.compact,
    icon: Icon(Icons.more_horiz_rounded, size: 18, color: color),
    onPressed: () {
      final box = context.findRenderObject()! as RenderBox;
      showCalendarBlockMenu(
        context,
        ref,
        block,
        box.localToGlobal(Offset(0, box.size.height)),
        includeQuickActions: includeQuickActions,
      );
    },
  );
}

class CalendarBlock extends ConsumerStatefulWidget {
  const CalendarBlock({
    super.key,
    required this.block,
    required this.day,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
    this.onDelete,
    this.planning = false,
    this.showMenuButton = false,
    this.highlighted = false,
  });
  final TimeBlock block;
  final DateTime day;
  final void Function(CalendarDragKind, Offset) onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd, onDragCancel;
  final VoidCallback? onDelete;
  final bool planning;
  final bool showMenuButton;
  final bool highlighted;
  @override
  ConsumerState<CalendarBlock> createState() => _CalendarBlockState();
}

class _CalendarBlockState extends ConsumerState<CalendarBlock> {
  bool editing = false;
  String? gestureOwner;
  bool get mobile =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  void beginDrag(String owner, CalendarDragKind kind, Offset position) {
    gestureOwner = owner;
    widget.onDragStart(kind, position);
  }

  void updateDrag(String owner, Offset position) {
    if (gestureOwner == owner) widget.onDragUpdate(position);
  }

  void endDrag(String owner, {bool cancel = false}) {
    if (gestureOwner != owner) return;
    gestureOwner = null;
    if (cancel) {
      widget.onDragCancel();
    } else {
      widget.onDragEnd();
    }
  }

  Future<void> menu(Offset position) =>
      showCalendarBlockMenu(context, ref, widget.block, position);

  Widget handle(
    bool beginning,
    Color color,
    double height,
    double controls,
  ) => Positioned(
    left: 0,
    right: controls,
    top: beginning ? 0 : null,
    bottom: beginning ? null : 0,
    height: math.min(mobile ? 20 : 9, height / 2),
    child: MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      child: RawGestureDetector(
        key: ValueKey(
          'block-resize-${beginning ? 'start' : 'end'}-${widget.block.id}',
        ),
        behavior: HitTestBehavior.opaque,
        gestures: {
          PanGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
                () => PanGestureRecognizer(
                  supportedDevices: const {
                    PointerDeviceKind.mouse,
                    PointerDeviceKind.touch,
                    PointerDeviceKind.stylus,
                  },
                ),
                (recognizer) => recognizer
                  // Keep the previous vertical handle's touch threshold while also
                  // following the pointer horizontally into a neighbouring day.
                  ..gestureSettings = DeviceGestureSettings(
                    touchSlop:
                        (MediaQuery.gestureSettingsOf(context).touchSlop ??
                            kTouchSlop) /
                        2,
                  )
                  ..dragStartBehavior = DragStartBehavior.down
                  ..onStart = (details) {
                    if (mobile) HapticFeedback.selectionClick();
                    beginDrag(
                      beginning ? 'resize-start' : 'resize-end',
                      beginning ? CalendarDragKind.start : CalendarDragKind.end,
                      details.globalPosition,
                    );
                  }
                  ..onUpdate = (details) {
                    updateDrag(
                      beginning ? 'resize-start' : 'resize-end',
                      details.globalPosition,
                    );
                  }
                  ..onEnd = (_) {
                    endDrag(beginning ? 'resize-start' : 'resize-end');
                  }
                  ..onCancel = () {
                    endDrag(
                      beginning ? 'resize-start' : 'resize-end',
                      cancel: true,
                    );
                  },
              ),
        },
        child: !widget.planning && (!mobile || !editing)
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
    final color = widget.onDelete != null
        ? context.palette.pink
        : context.palette.accent(Color(repo.snapshot.taskColor(task)));
    final running = repo.snapshot.sessions.any(
      (s) => s.taskId == task.id && s.running,
    );
    final canPan = !mobile || editing || widget.planning;
    return Listener(
      onPointerCancel: (_) {
        if (gestureOwner != null) {
          gestureOwner = null;
          widget.onDragCancel();
        }
      },
      child: LayoutBuilder(
        builder: (context, bounds) {
          final height = bounds.maxHeight;
          final zone = tz.getLocation(repo.snapshot.settings.timezone);
          final dayEnd = tz.TZDateTime(
            zone,
            widget.day.year,
            widget.day.month,
            widget.day.day + 1,
          );
          return TapRegion(
            onTapOutside: (_) {
              if (editing && mounted) setState(() => editing = false);
            },
            child: GestureDetector(
              key: ValueKey('calendar-block-${widget.block.id}'),
              supportedDevices: const {
                PointerDeviceKind.mouse,
                PointerDeviceKind.touch,
                PointerDeviceKind.stylus,
              },
              onTap: () {
                if (widget.onDelete == null && !widget.planning) {
                  openTask(context, task: task, blockId: widget.block.id);
                } else {
                  setState(() => editing = true);
                }
              },
              onSecondaryTapDown: widget.onDelete == null && !widget.planning
                  ? (d) => menu(d.globalPosition)
                  : null,
              dragStartBehavior: DragStartBehavior.down,
              onLongPressStart: (details) {
                HapticFeedback.mediumImpact();
                setState(() => editing = true);
                beginDrag(
                  'hold',
                  CalendarDragKind.move,
                  details.globalPosition,
                );
              },
              onLongPressMoveUpdate: (details) =>
                  updateDrag('hold', details.globalPosition),
              onLongPressEnd: (_) => endDrag('hold'),
              onLongPressCancel: () => endDrag('hold', cancel: true),
              onPanStart: !canPan
                  ? null
                  : (details) => beginDrag(
                      'pan',
                      CalendarDragKind.move,
                      details.globalPosition,
                    ),
              onPanUpdate: !canPan
                  ? null
                  : (details) => updateDrag('pan', details.globalPosition),
              onPanEnd: !canPan ? null : (_) => endDrag('pan'),
              onPanCancel: !canPan ? null : () => endDrag('pan', cancel: true),
              child: Container(
                height: height,
                decoration: BoxDecoration(
                  color: context.palette.taskSurface(
                    color,
                    subdued: task.done || widget.block.historical,
                    selected: editing || widget.planning || widget.highlighted,
                  ),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: editing || widget.planning || widget.highlighted
                        ? color
                        : color.withValues(alpha: .28),
                    width: editing || widget.planning || widget.highlighted
                        ? 1.5
                        : .7,
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
                    final showMenu =
                        widget.showMenuButton &&
                        widget.onDelete == null &&
                        !widget.planning;
                    final showControls =
                        widget.onDelete == null &&
                        !widget.planning &&
                        c.maxWidth >= (showMenu ? 88 : 60);
                    final controlsWidth = widget.planning
                        ? 0.0
                        : widget.onDelete != null
                        ? 29.0
                        : (showControls ? (task.done ? 25.0 : 50.0) : 0.0) +
                              (showMenu ? 25.0 : 0.0) +
                              4;
                    final zone = tz.getLocation(
                      repo.snapshot.settings.timezone,
                    );
                    final begin = widget.block.start;
                    final finish = widget.block.end;
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
                                  ? context.palette.pink
                                  : color.withValues(alpha: .8),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                        Padding(
                          padding: EdgeInsets.fromLTRB(9, small ? 0 : 7, 4, 0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      widget.onDelete == null
                                          ? task.title
                                          : '${DateFormat('HH:mm').format(tz.TZDateTime.from(begin, zone))} — ${DateFormat('HH:mm').format(tz.TZDateTime.from(finish, zone))}',
                                      maxLines: small ? 1 : 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: task.done
                                            ? context.palette.muted
                                            : color,
                                        decoration: task.done
                                            ? TextDecoration.lineThrough
                                            : null,
                                      ),
                                    ),
                                  ),
                                  if (widget.onDelete != null)
                                    SizedBox(
                                      width: 25,
                                      height: math.min(24, c.maxHeight),
                                      child: IconButton(
                                        key: ValueKey(
                                          'remove-time-${widget.block.id}',
                                        ),
                                        padding: EdgeInsets.zero,
                                        tooltip: tr("Убрать интервал"),
                                        onPressed: widget.onDelete,
                                        icon: Icon(
                                          Icons.close_rounded,
                                          size: 15,
                                          color: context.palette.pink,
                                        ),
                                      ),
                                    ),
                                  if (showControls) ...[
                                    SizedBox(
                                      width: 25,
                                      height: math.min(24, c.maxHeight),
                                      child: IconButton(
                                        key: ValueKey(
                                          'calendar-complete-${widget.block.id}',
                                        ),
                                        padding: EdgeInsets.zero,
                                        tooltip: task.done
                                            ? tr("Вернуть в работу")
                                            : tr("Завершить"),
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
                                              ? tr("Остановить")
                                              : tr("Начать работу"),
                                          onPressed: () => guard(
                                            context,
                                            () =>
                                                repo.toggleCalendarTimer(task),
                                          ),
                                          icon: Icon(
                                            running
                                                ? Icons.pause_rounded
                                                : Icons.play_arrow_rounded,
                                            size: 19,
                                            color: running
                                                ? context.palette.pink
                                                : color,
                                          ),
                                        ),
                                      ),
                                  ],
                                  if (showMenu)
                                    SizedBox(
                                      width: math.min(
                                        25,
                                        math.max(0, c.maxWidth - 13),
                                      ),
                                      height: math.min(24, c.maxHeight),
                                      child: CalendarEventMenuButton(
                                        block: widget.block,
                                        color: color,
                                        includeQuickActions: !showControls,
                                      ),
                                    ),
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
                        if (!mobile || editing || widget.planning) ...[
                          if (!widget.block.start.isBefore(widget.day))
                            handle(
                              true,
                              color,
                              height,
                              math.min(c.maxWidth, controlsWidth),
                            ),
                          if (!widget.block.end.isAfter(dayEnd))
                            handle(
                              false,
                              color,
                              height,
                              math.min(c.maxWidth, controlsWidth),
                            ),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _WorkdayLinePainter extends CustomPainter {
  const _WorkdayLinePainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    for (var x = 0.0; x < size.width; x += 8) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(math.min(x + 4, size.width), 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WorkdayLinePainter old) => old.color != color;
}

class _GridPainter extends CustomPainter {
  _GridPainter({
    required this.count,
    required this.columnWidth,
    required this.hourHeight,
    required this.gutter,
    required this.border,
  });
  final int count;
  final double columnWidth, hourHeight, gutter;
  final Color border;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = border.withValues(alpha: .65)
      ..strokeWidth = .5;
    final half = Paint()
      ..color = border.withValues(alpha: .25)
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
      old.count != count ||
      old.columnWidth != columnWidth ||
      old.hourHeight != hourHeight ||
      old.gutter != gutter ||
      old.border != border;
}
