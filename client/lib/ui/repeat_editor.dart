import '../l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;
import '../domain/recurrence.dart';
import 'theme.dart';

final repeatPresets = {
  '': tr("Не повторять"),
  'FREQ=DAILY': tr("Каждый день"),
  'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR': tr("По будням"),
  'FREQ=WEEKLY': tr("Каждую неделю"),
  'FREQ=MONTHLY': tr("Каждый месяц"),
  'FREQ=YEARLY': tr("Каждый год"),
};
final repeatWeekdays = {
  'MO': tr("Пн"),
  'TU': tr("Вт"),
  'WE': tr("Ср"),
  'TH': tr("Чт"),
  'FR': tr("Пт"),
  'SA': tr("Сб"),
  'SU': tr("Вс"),
};

String repeatLabel(String value) {
  if (repeatPresets.containsKey(value)) return repeatPresets[value]!;
  final fields = {
    for (final part in value.replaceFirst('RRULE:', '').split(';'))
      if (part.contains('=')) part.split('=').first: part.split('=').last,
  };
  final unit =
      {
        'DAILY': tr("дн."),
        'WEEKLY': tr("нед."),
        'MONTHLY': tr("мес."),
        'YEARLY': tr("г."),
      }[fields['FREQ']] ??
      '';
  final days = (fields['BYDAY'] ?? '')
      .split(',')
      .map((d) => repeatWeekdays[d] ?? d)
      .where((d) => d.isNotEmpty)
      .join(', ');
  return tr("Каждые {0} {1}{2}", [
    fields['INTERVAL'] ?? '1',
    unit,
    days.isEmpty ? '' : ' · $days',
  ]);
}

class RepeatPicker extends StatelessWidget {
  const RepeatPicker({
    super.key,
    required this.value,
    required this.start,
    required this.timezone,
    required this.onChanged,
    this.compact = false,
  });
  final String value, timezone;
  final DateTime start;
  final ValueChanged<String> onChanged;
  final bool compact;
  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
    key: ValueKey(value),
    isExpanded: true,
    style: compact
        ? TextStyle(
            fontFamily: 'Inter',
            fontSize: 12,
            color: context.palette.text,
          )
        : null,
    icon: Icon(
      Icons.expand_more_rounded,
      size: 18,
      color: context.palette.muted,
    ),
    selectedItemBuilder: compact
        ? (context) => [
            for (final label in [...repeatPresets.values, repeatLabel(value)])
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ]
        : null,
    initialValue: repeatPresets.containsKey(value) ? value : 'custom',
    decoration: compact
        ? const InputDecoration(
            filled: false,
            isDense: true,
            contentPadding: EdgeInsets.symmetric(vertical: 8),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
          )
        : InputDecoration(
            labelText: tr("Повторение"),
            prefixIcon: Icon(Icons.repeat_rounded, size: 19),
          ),
    items: [
      for (final entry in repeatPresets.entries)
        DropdownMenuItem(value: entry.key, child: Text(entry.value)),
      DropdownMenuItem(
        value: 'custom',
        child: Text(
          repeatPresets.containsKey(value)
              ? tr("Настроить повторение…")
              : repeatLabel(value),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
    onChanged: (next) async {
      if (next == 'custom') {
        final result = await showDialog<String>(
          context: context,
          builder: (_) =>
              RepeatEditor(initial: value, start: start, timezone: timezone),
        );
        if (result != null && context.mounted) onChanged(result);
      } else if (next != null) {
        onChanged(next);
      }
    },
  );
}

class RepeatEditor extends StatefulWidget {
  const RepeatEditor({
    super.key,
    required this.initial,
    required this.start,
    required this.timezone,
  });
  final String initial, timezone;
  final DateTime start;
  @override
  State<RepeatEditor> createState() => _RepeatEditorState();
}

class _RepeatEditorState extends State<RepeatEditor> {
  String frequency = 'WEEKLY', monthly = 'date';
  late final TextEditingController interval;
  late final DateTime start;
  final days = <String>{};
  String? error;
  int get ordinal => (start.day - 1) ~/ 7 + 1;
  String get weekday => repeatWeekdays.keys.elementAt(start.weekday - 1);
  @override
  void initState() {
    super.initState();
    start = tz.TZDateTime.from(widget.start, tz.getLocation(widget.timezone));
    final fields = {
      for (final part in widget.initial.replaceFirst('RRULE:', '').split(';'))
        if (part.contains('=')) part.split('=').first: part.split('=').last,
    };
    frequency = fields['FREQ'] ?? frequency;
    interval = TextEditingController(text: fields['INTERVAL'] ?? '1');
    days.addAll(
      (fields['BYDAY'] ?? weekday).split(',').where(repeatWeekdays.containsKey),
    );
    if (days.isEmpty) days.add(weekday);
    if (frequency == 'MONTHLY' && fields.containsKey('BYDAY')) {
      monthly = 'weekday';
    }
  }

  @override
  void dispose() {
    interval.dispose();
    super.dispose();
  }

  void save() {
    final n = int.tryParse(interval.text);
    if (n == null ||
        n < 1 ||
        n > 999 ||
        (frequency == 'WEEKLY' && days.isEmpty)) {
      setState(
        () => error = tr(
          "Интервал — от 1 до 999. Выберите хотя бы один день недели.",
        ),
      );
      return;
    }
    var rule = 'FREQ=$frequency;INTERVAL=$n';
    if (frequency == 'WEEKLY') {
      rule += ';BYDAY=${repeatWeekdays.keys.where(days.contains).join(',')}';
    }
    if (frequency == 'MONTHLY') {
      rule += monthly == 'date'
          ? ';BYMONTHDAY=${start.day}'
          : ';BYDAY=${ordinal == 5 ? -1 : ordinal}$weekday';
    }
    RecurrenceService.parse(rule);
    Navigator.pop(context, rule);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr("Настроить повторение")),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr("ПОВТОРЯТЬ КАЖДЫЕ"),
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 1.4,
                color: context.palette.muted,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 84,
                  child: TextField(
                    key: const ValueKey('repeat-interval'),
                    controller: interval,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: tr("Интервал")),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: frequency,
                    items: [
                      DropdownMenuItem(value: 'DAILY', child: Text(tr("дни"))),
                      DropdownMenuItem(
                        value: 'WEEKLY',
                        child: Text(tr("недели")),
                      ),
                      DropdownMenuItem(
                        value: 'MONTHLY',
                        child: Text(tr("месяцы")),
                      ),
                      DropdownMenuItem(
                        value: 'YEARLY',
                        child: Text(tr("годы")),
                      ),
                    ],
                    onChanged: (v) => setState(() => frequency = v!),
                  ),
                ),
              ],
            ),
            if (frequency == 'WEEKLY') ...[
              const SizedBox(height: 22),
              Text(
                tr("В ДНИ НЕДЕЛИ"),
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.4,
                  color: context.palette.muted,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final day in repeatWeekdays.entries)
                    FilterChip(
                      label: Text(day.value),
                      selected: days.contains(day.key),
                      onSelected: (v) => setState(
                        () => v ? days.add(day.key) : days.remove(day.key),
                      ),
                    ),
                ],
              ),
            ],
            if (frequency == 'MONTHLY') ...[
              const SizedBox(height: 20),
              DropdownButtonFormField<String>(
                initialValue: monthly,
                isExpanded: true,
                items: [
                  DropdownMenuItem(
                    value: 'date',
                    child: Text(tr("Каждое {0}-е число", [start.day])),
                  ),
                  DropdownMenuItem(
                    value: 'weekday',
                    child: Text(
                      tr("{0} {1} месяца", [
                        ordinal == 5 ? tr("Последний") : tr("{0}-й", [ordinal]),
                        repeatWeekdays[weekday],
                      ]),
                    ),
                  ),
                ],
                onChanged: (v) => setState(() => monthly = v!),
              ),
            ],
            const SizedBox(height: 20),
            Text(
              tr(
                "Повторяется, пока вы не удалите серию или последующие задачи.",
              ),
              style: TextStyle(
                color: context.palette.muted,
                fontSize: 12,
                height: 1.5,
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr("Отмена")),
      ),
      FilledButton(onPressed: save, child: Text(tr("Готово"))),
    ],
  );
}
