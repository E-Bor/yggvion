import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;
import 'repeat_editor.dart';
import 'theme.dart';

/// Shared civil date/time controls for new events and existing calendar blocks.
class ScheduleFields extends StatelessWidget {
  const ScheduleFields({
    super.key,
    required this.start,
    required this.end,
    required this.allDay,
    required this.timezone,
    required this.onChanged,
    this.rule,
    this.onRuleChanged,
  });
  final DateTime start, end;
  final bool allDay;
  final String timezone;
  final String? rule;
  final ValueChanged<String>? onRuleChanged;
  final void Function(DateTime start, DateTime end, bool allDay) onChanged;

  tz.Location get zone => tz.getLocation(timezone);
  DateTime civil(DateTime date, {int? hour, int? minute, int days = 0}) =>
      tz.TZDateTime(
        zone,
        date.year,
        date.month,
        date.day + days,
        hour ?? date.hour,
        minute ?? date.minute,
      );
  DateTime get visibleEnd => allDay ? civil(end, days: -1) : end;

  void changeStart(DateTime next) {
    final span = DateTime.utc(
      end.year,
      end.month,
      end.day,
    ).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
    onChanged(
      next,
      allDay ? civil(next, days: span) : next.add(end.difference(start)),
      allDay,
    );
  }

  Future<void> date(BuildContext context, bool beginning) async {
    final current = beginning ? start : visibleEnd;
    final value = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(1970),
      lastDate: DateTime(2200),
    );
    if (value == null || !context.mounted) return;
    final next = civil(value, hour: current.hour, minute: current.minute);
    if (beginning) {
      changeStart(next);
    } else {
      onChanged(start, allDay ? civil(next, days: 1) : next, allDay);
    }
  }

  Future<void> time(BuildContext context, bool beginning) async {
    final current = beginning ? start : end;
    final value = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
      initialEntryMode: TimePickerEntryMode.input,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (value == null || !context.mounted) return;
    var next = civil(current, hour: value.hour, minute: value.minute);
    if (beginning) {
      changeStart(next);
    } else {
      if (!next.isAfter(start) && DateUtils.isSameDay(start, next)) {
        next = civil(next, days: 1);
      }
      onChanged(start, next, false);
    }
  }

  Widget field(String key, String label, String tooltip, VoidCallback onTap) =>
      TextButton(
        key: ValueKey(key),
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: Palette.text,
          minimumSize: const Size(0, 38),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 14),
        ),
        child: Tooltip(message: tooltip, child: Text(label)),
      );

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Padding(
        padding: EdgeInsets.only(top: 10, right: 12),
        child: Icon(Icons.schedule_rounded, size: 20, color: Palette.muted),
      ),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final firstDate = field(
                  'schedule-start-date',
                  DateFormat('d MMM y', 'ru').format(start),
                  'Дата начала',
                  () => date(context, true),
                );
                final lastDate = field(
                  'schedule-end-date',
                  DateFormat('d MMM y', 'ru').format(visibleEnd),
                  'Дата окончания',
                  () => date(context, false),
                );
                final firstTime = field(
                  'schedule-start-time',
                  DateFormat('HH:mm').format(start),
                  'Время начала',
                  () => time(context, true),
                );
                final lastTime = field(
                  'schedule-end-time',
                  DateFormat('HH:mm').format(end),
                  'Время окончания',
                  () => time(context, false),
                );
                const dash = Text('—', style: TextStyle(color: Palette.muted));
                if (constraints.maxWidth < 420) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [firstDate, dash, lastDate],
                      ),
                      if (!allDay) Row(children: [firstTime, dash, lastTime]),
                    ],
                  );
                }
                return Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    firstDate,
                    if (!allDay) firstTime,
                    dash,
                    if (!allDay) lastTime,
                    lastDate,
                  ],
                );
              },
            ),
            Row(
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => toggleAllDay(!allDay),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 32,
                        height: 38,
                        child: Checkbox(
                          key: const ValueKey('schedule-all-day'),
                          value: allDay,
                          onChanged: (value) => toggleAllDay(value!),
                        ),
                      ),
                      const Text('Весь день', style: TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
                if (rule != null && onRuleChanged != null) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: RepeatPicker(
                      value: rule!,
                      start: start,
                      timezone: timezone,
                      onChanged: onRuleChanged!,
                      compact: true,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    ],
  );

  void toggleAllDay(bool value) {
    if (value) {
      final first = civil(start, hour: 0, minute: 0);
      var finish = civil(end, hour: 0, minute: 0);
      if (end.hour != 0 || end.minute != 0 || !finish.isAfter(first)) {
        finish = civil(finish, days: 1);
      }
      onChanged(first, finish, true);
    } else {
      onChanged(start, end, false);
    }
  }
}
