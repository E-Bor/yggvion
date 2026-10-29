import '../l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'calendar.dart';
import 'notes.dart';
import 'providers.dart';
import 'theme.dart';

class Dashboard extends ConsumerStatefulWidget {
  const Dashboard({
    super.key,
    required this.projectId,
    this.date,
    this.focus,
    this.onDateChanged,
  });
  final String projectId;
  final DateTime? date;
  final CalendarFocus? focus;
  final ValueChanged<DateTime>? onDateChanged;
  @override
  ConsumerState<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends ConsumerState<Dashboard> {
  late double calendar, scratchpad;
  @override
  void initState() {
    super.initState();
    final repo = ref.read(appProvider);
    calendar = repo.calendarFraction;
    scratchpad = repo.scratchpadFraction;
  }

  void save() => guard(
    context,
    () => ref.read(appProvider).saveHomeLayout(calendar, scratchpad),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      // Keep both work surfaces usable even in a short desktop window.
      final available = (c.maxHeight - 16).clamp(1.0, double.infinity);
      final minCalendar = (260 / available).clamp(.25, .65);
      final maxCalendar = (1 - 150 / available).clamp(minCalendar, .85);
      final calendarHeight =
          available * calendar.clamp(minCalendar, maxCalendar);
      return Column(
        children: [
          SizedBox(
            height: calendarHeight,
            child: CalendarPane(
              projectId: widget.projectId,
              initialDate: widget.date,
              focus: widget.focus,
              onDateChanged: widget.onDateChanged,
              showToolbar: false,
            ),
          ),
          PanelDivider(
            key: const ValueKey('calendar-notes-divider'),
            axis: Axis.horizontal,
            label: tr("Размер календаря и заметок"),
            onDelta: (delta) => setState(
              () => calendar = (calendar + delta / available).clamp(
                minCalendar,
                maxCalendar,
              ),
            ),
            onEnd: save,
            onReset: () {
              setState(() => calendar = .64);
              save();
            },
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, notes) {
                final width = notes.maxWidth - 16;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: width * scratchpad.clamp(.25, .75),
                      child: const NotePanel(noteId: 'scratchpad', fill: true),
                    ),
                    PanelDivider(
                      key: const ValueKey('scratchpad-reference-divider'),
                      axis: Axis.vertical,
                      label: tr("Размер черновика и справочной заметки"),
                      onDelta: (delta) => setState(
                        () => scratchpad = (scratchpad + delta / width).clamp(
                          .25,
                          .75,
                        ),
                      ),
                      onEnd: save,
                      onReset: () {
                        setState(() => scratchpad = .62);
                        save();
                      },
                    ),
                    const Expanded(
                      child: NotePanel(noteId: 'reference', fill: true),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      );
    },
  );
}

class PanelDivider extends StatefulWidget {
  const PanelDivider({
    super.key,
    required this.axis,
    required this.label,
    required this.onDelta,
    required this.onEnd,
    required this.onReset,
  });
  final Axis axis;
  final String label;
  final ValueChanged<double> onDelta;
  final VoidCallback onEnd, onReset;
  @override
  State<PanelDivider> createState() => _PanelDividerState();
}

class _PanelDividerState extends State<PanelDivider> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final horizontal = widget.axis == Axis.horizontal;
    return Semantics(
      label: widget.label,
      onIncrease: () {
        widget.onDelta(24);
        widget.onEnd();
      },
      onDecrease: () {
        widget.onDelta(-24);
        widget.onEnd();
      },
      child: Tooltip(
        message: tr("{0} · потяните, двойной клик — сброс", [widget.label]),
        child: MouseRegion(
          cursor: horizontal
              ? SystemMouseCursors.resizeUpDown
              : SystemMouseCursors.resizeLeftRight,
          onEnter: (_) => setState(() => hover = true),
          onExit: (_) => setState(() => hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: widget.onReset,
            onPanUpdate: (d) =>
                widget.onDelta(horizontal ? d.delta.dy : d.delta.dx),
            onPanEnd: (_) => widget.onEnd(),
            onPanCancel: widget.onEnd,
            child: SizedBox(
              width: horizontal ? double.infinity : 16,
              height: horizontal ? 16 : double.infinity,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: horizontal ? 40 : 3,
                  height: horizontal ? 3 : 40,
                  decoration: BoxDecoration(
                    color: hover ? context.accentColor : context.palette.border,
                    borderRadius: BorderRadius.circular(3),
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
