import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;
import '../domain/models.dart';
import '../domain/recurrence.dart';
import 'markdown_editor.dart';
import 'providers.dart';
import 'repeat_editor.dart';
import 'theme.dart';

Future<void> openTask(
  BuildContext context, {
  Task? task,
  DateTime? start,
  DateTime? end,
}) => showDialog<void>(
  context: context,
  builder: (_) => TaskEditor(taskId: task?.id, start: start, end: end),
);
Future<DateTime?> pickDateTime(
  BuildContext context,
  DateTime initial, {
  bool dateOnly = false,
}) async {
  final date = await showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime(1970),
    lastDate: DateTime(2200),
  );
  if (date == null || !context.mounted) return null;
  if (dateOnly) return date;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(initial),
  );
  if (time == null) return null;
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

class DateTimeButton extends StatelessWidget {
  const DateTimeButton({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.dateOnly = false,
  });
  final String label;
  final DateTime value;
  final ValueChanged<DateTime> onChanged;
  final bool dateOnly;
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: () async {
      final next = await pickDateTime(context, value, dateOnly: dateOnly);
      if (next != null) onChanged(next);
    },
    icon: const Icon(Icons.calendar_today_outlined, size: 16),
    label: Text(
      '$label ${DateFormat(dateOnly ? 'd MMM y' : 'd MMM, HH:mm', 'ru').format(value)}',
    ),
  );
}

Future<void> editSession(
  BuildContext context,
  Task task, {
  WorkSession? session,
}) => showDialog<void>(
  context: context,
  builder: (_) => SessionEditor(task: task, session: session),
);

class SessionEditor extends ConsumerStatefulWidget {
  const SessionEditor({super.key, required this.task, this.session});
  final Task task;
  final WorkSession? session;
  @override
  ConsumerState<SessionEditor> createState() => _SessionEditorState();
}

class _SessionEditorState extends ConsumerState<SessionEditor> {
  late DateTime start, end;
  late tz.Location zone;
  bool saving = false;
  @override
  void initState() {
    super.initState();
    final repo = ref.read(appProvider);
    zone = tz.getLocation(repo.snapshot.settings.timezone);
    end = tz.TZDateTime.from(widget.session?.end ?? repo.now(), zone);
    start = tz.TZDateTime.from(
      widget.session?.start ?? end.subtract(const Duration(minutes: 30)),
      zone,
    );
  }

  DateTime inZone(DateTime d) =>
      tz.TZDateTime(zone, d.year, d.month, d.day, d.hour, d.minute);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.session == null
          ? 'Добавить потраченное время'
          : 'Изменить потраченное время',
    ),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.task.title, style: const TextStyle(color: Palette.muted)),
          const SizedBox(height: 20),
          DateTimeButton(
            label: 'С',
            value: start,
            onChanged: (v) => setState(() => start = inZone(v)),
          ),
          const SizedBox(height: 12),
          DateTimeButton(
            label: 'До',
            value: end,
            onChanged: (v) => setState(() => end = inZone(v)),
          ),
          const SizedBox(height: 20),
          Text('Длительность: ${formatDuration(end.difference(start))}'),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: saving
            ? null
            : () => guard(context, () async {
                setState(() => saving = true);
                try {
                  await ref
                      .read(appProvider)
                      .saveSession(
                        widget.task.id,
                        start,
                        end,
                        session: widget.session,
                      );
                  if (context.mounted) Navigator.pop(context);
                } finally {
                  if (mounted) setState(() => saving = false);
                }
              }),
        child: const Text('Сохранить'),
      ),
    ],
  );
}

Future<void> editBlock(BuildContext context, TimeBlock block) =>
    showDialog<void>(
      context: context,
      builder: (_) => BlockEditor(block: block),
    );

Future<RepeatScope?> chooseScope(
  BuildContext context, {
  String title = 'Изменить повторение',
}) => showDialog<RepeatScope>(
  context: context,
  builder: (c) => SimpleDialog(
    title: Text(title),
    children: [
      for (final scope in RepeatScope.values)
        SimpleDialogOption(
          onPressed: () => Navigator.pop(c, scope),
          child: Text(
            scope == RepeatScope.instance
                ? 'Только эту задачу'
                : scope == RepeatScope.following
                ? 'Эту и последующие'
                : 'Всю серию',
          ),
        ),
    ],
  ),
);

Future<bool> deleteTask(BuildContext context, WidgetRef ref, Task task) async {
  RepeatScope? scope;
  if (task.seriesId.isNotEmpty) {
    scope = await chooseScope(context, title: 'Удалить повторяющуюся задачу');
  } else {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Удалить задачу?'),
        content: Text(
          '«${task.title}» и её записи времени будут удалены на всех устройствах.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed == true) scope = RepeatScope.instance;
  }
  if (scope == null || !context.mounted) return false;
  await RecurrenceService(ref.read(appProvider)).delete(task, scope);
  return true;
}

Future<void> moveCalendarBlock(
  BuildContext context,
  WidgetRef ref,
  TimeBlock block,
  DateTime start,
  DateTime end, {
  String? timezone,
  bool? allDay,
  List<int>? reminders,
}) async {
  final repo = ref.read(appProvider);
  var scope = RepeatScope.instance;
  if (repo.snapshot.task(block.taskId)?.seriesId.isNotEmpty == true) {
    final chosen = await chooseScope(context);
    if (chosen == null) return;
    scope = chosen;
  }
  await RecurrenceService(repo).editTiming(
    block,
    scope,
    start,
    end,
    timezone: timezone ?? block.timezone,
    allDay: allDay ?? block.allDay,
    reminders: reminders ?? block.reminders,
  );
}

class BlockEditor extends ConsumerStatefulWidget {
  const BlockEditor({super.key, required this.block});
  final TimeBlock block;
  @override
  ConsumerState<BlockEditor> createState() => _BlockEditorState();
}

class _BlockEditorState extends ConsumerState<BlockEditor> {
  late DateTime start, end;
  late bool allDay;
  late List<int> reminders;
  late String zone;
  @override
  void initState() {
    super.initState();
    zone = ref.read(appProvider).snapshot.settings.timezone;
    start = tz.TZDateTime.from(widget.block.start, tz.getLocation(zone));
    end = tz.TZDateTime.from(widget.block.end, tz.getLocation(zone));
    allDay = widget.block.allDay;
    reminders = [...widget.block.reminders];
  }

  DateTime inZone(DateTime d) => tz.TZDateTime(
    tz.getLocation(zone),
    d.year,
    d.month,
    d.day,
    d.hour,
    d.minute,
  );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Календарный блок'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DateTimeButton(
              label: 'Начало',
              value: start,
              dateOnly: allDay,
              onChanged: (v) => setState(() => start = inZone(v)),
            ),
            const SizedBox(height: 12),
            DateTimeButton(
              label: 'Конец',
              value: end,
              dateOnly: allDay,
              onChanged: (v) => setState(() => end = inZone(v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('На весь день'),
              subtitle: const Text('Конец — начало следующего дня'),
              value: allDay,
              onChanged: (v) => setState(() {
                allDay = v;
                if (v) {
                  start = tz.TZDateTime(
                    tz.getLocation(zone),
                    start.year,
                    start.month,
                    start.day,
                  );
                  end = tz.TZDateTime(
                    tz.getLocation(zone),
                    start.year,
                    start.month,
                    start.day + 1,
                  );
                }
              }),
            ),
            const SizedBox(height: 18),
            ReminderPicker(
              values: reminders,
              onChanged: (v) => setState(() => reminders = v),
            ),
            const SizedBox(height: 12),
            Text(
              'План: ${formatDuration(end.difference(start))}',
              style: const TextStyle(color: Palette.muted),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () => guard(context, () async {
          await moveCalendarBlock(
            context,
            ref,
            widget.block,
            start,
            end,
            allDay: allDay,
            reminders: reminders,
            timezone: zone,
          );
          if (context.mounted) Navigator.pop(context);
        }),
        child: const Text('Сохранить'),
      ),
    ],
  );
}

class TimezoneField extends StatelessWidget {
  const TimezoneField({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final String value;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) => Autocomplete<String>(
    initialValue: TextEditingValue(text: value),
    optionsBuilder: (v) => tz.timeZoneDatabase.locations.keys
        .where((s) => s.toLowerCase().contains(v.text.toLowerCase()))
        .take(30),
    onSelected: onChanged,
    fieldViewBuilder: (context, controller, focus, onSubmitted) => TextField(
      controller: controller,
      focusNode: focus,
      decoration: const InputDecoration(labelText: 'Часовой пояс IANA'),
      onSubmitted: (v) {
        try {
          tz.getLocation(v);
          onChanged(v);
        } catch (e) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Выберите часовой пояс из списка')),
          );
        }
      },
    ),
  );
}

class ReminderOffsetEditor extends StatefulWidget {
  const ReminderOffsetEditor({super.key});
  @override
  State<ReminderOffsetEditor> createState() => _ReminderOffsetEditorState();
}

class _ReminderOffsetEditorState extends State<ReminderOffsetEditor> {
  final amount = TextEditingController(text: '1');
  int unit = 60;
  String? error;
  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Напомнить заранее'),
    content: SizedBox(
      width: 360,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('reminder-amount'),
              controller: amount,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: 'За', errorText: error),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<int>(
              key: const ValueKey('reminder-unit'),
              initialValue: unit,
              items: const [
                DropdownMenuItem(value: 1, child: Text('минут')),
                DropdownMenuItem(value: 60, child: Text('часов')),
                DropdownMenuItem(value: 1440, child: Text('дней')),
                DropdownMenuItem(value: 10080, child: Text('недель')),
              ],
              onChanged: (v) => setState(() => unit = v!),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          final n = int.tryParse(amount.text);
          if (n == null || n < 0 || n * unit > 525600) {
            setState(() => error = 'От 0 до ${525600 ~/ unit}');
          } else {
            Navigator.pop(context, n * unit);
          }
        },
        child: const Text('Добавить'),
      ),
    ],
  );
}

class ReminderPicker extends StatelessWidget {
  const ReminderPicker({
    super.key,
    required this.values,
    required this.onChanged,
  });
  final List<int> values;
  final ValueChanged<List<int>> onChanged;
  Future<void> custom(BuildContext context) async {
    final result = await showDialog<int>(
      context: context,
      builder: (_) => const ReminderOffsetEditor(),
    );
    if (result != null) onChanged({...values, result}.toList()..sort());
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Напомнить',
        style: TextStyle(color: Palette.muted, fontSize: 12),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final minutes in {0, 5, 10, 15, 30, 60, 1440, ...values})
            FilterChip(
              label: Text(
                minutes == 0
                    ? 'В начале'
                    : minutes >= 10080 && minutes % 10080 == 0
                    ? 'За ${minutes ~/ 10080} нед'
                    : minutes >= 1440 && minutes % 1440 == 0
                    ? 'За ${minutes ~/ 1440} д'
                    : minutes >= 60 && minutes % 60 == 0
                    ? 'За ${minutes ~/ 60} ч'
                    : 'За $minutes мин',
              ),
              selected: values.contains(minutes),
              onSelected: !values.contains(minutes) && values.length >= 12
                  ? null
                  : (v) => onChanged(
                      v
                          ? [...values, minutes]
                          : values.where((m) => m != minutes).toList(),
                    ),
            ),
          if (values.length < 12)
            ActionChip(
              label: const Text('Другое…'),
              onPressed: () => custom(context),
            ),
        ],
      ),
    ],
  );
}

class TaskEditor extends ConsumerStatefulWidget {
  const TaskEditor({super.key, this.taskId, this.start, this.end});
  final String? taskId;
  final DateTime? start, end;
  @override
  ConsumerState<TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends ConsumerState<TaskEditor> {
  final title = TextEditingController();
  String description = '',
      projectId = '',
      rule = '',
      initialRule = '',
      zone = 'UTC';
  DateTime? start, end;
  bool allDay = false, saving = false;
  List<int> reminders = [];
  @override
  void initState() {
    super.initState();
    final repo = ref.read(appProvider);
    final task = repo.snapshot.task(widget.taskId ?? '');
    title.text = task?.title ?? '';
    description = task?.description ?? '';
    projectId = task?.projectId ?? '';
    if (task != null && task.seriesId.isNotEmpty) {
      initialRule =
          repo.snapshot.entities
                  .where((e) => e.id == task.seriesId)
                  .firstOrNull
                  ?.data['rule']
              as String? ??
          '';
      rule = initialRule;
    }
    start = widget.start;
    end =
        widget.end ??
        start?.add(Duration(minutes: repo.snapshot.settings.defaultMinutes));
    zone = repo.snapshot.settings.timezone;
    if (start != null) start = tz.TZDateTime.from(start!, tz.getLocation(zone));
    if (end != null) end = tz.TZDateTime.from(end!, tz.getLocation(zone));
    reminders = [...repo.snapshot.settings.reminders];
  }

  @override
  void dispose() {
    title.dispose();
    super.dispose();
  }

  Future<void> save() async {
    await guard(context, () async {
      if (title.text.trim().isEmpty) throw ArgumentError('Введите название');
      if (rule.isNotEmpty) RecurrenceService.parse(rule);
      setState(() => saving = true);
      try {
        final repo = ref.read(appProvider);
        final task = repo.snapshot.task(widget.taskId ?? '');
        if (task == null) {
          final created = await repo.createTask(
            title.text,
            description: description,
            projectId: projectId,
            start: start,
            end: end,
            allDay: allDay,
            reminders: reminders,
            timezone: zone,
          );
          if (rule.isNotEmpty && start != null) {
            await RecurrenceService(
              repo,
            ).create(created, repo.snapshot.taskBlocks(created.id).first, rule);
          }
        } else {
          RepeatScope scope = RepeatScope.instance;
          if (task.seriesId.isNotEmpty && rule == initialRule && mounted) {
            final selected = await showDialog<RepeatScope>(
              context: context,
              builder: (c) => SimpleDialog(
                title: const Text('Изменить повторение'),
                children: [
                  for (final s in RepeatScope.values)
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(c, s),
                      child: Text(
                        s == RepeatScope.instance
                            ? 'Только эту задачу'
                            : s == RepeatScope.following
                            ? 'Эту и последующие'
                            : 'Всю серию',
                      ),
                    ),
                ],
              ),
            );
            if (selected == null) return;
            scope = selected;
          }
          await RecurrenceService(repo).edit(
            task,
            scope,
            title: title.text.trim(),
            description: description,
            projectId: projectId,
          );
          if (rule != initialRule) {
            await RecurrenceService(
              repo,
            ).changeRuleFrom(repo.snapshot.task(task.id)!, rule);
          }
        }
        if (mounted) Navigator.pop(context);
      } finally {
        if (mounted) setState(() => saving = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(appProvider),
        task = repo.snapshot.task(widget.taskId ?? '');
    final blocks = task == null
        ? <TimeBlock>[]
        : repo.snapshot.taskBlocks(task.id);
    final sessions =
        task == null
              ? <WorkSession>[]
              : repo.snapshot.sessions
                    .where((s) => s.taskId == task.id && !s.discarded)
                    .toList()
          ..sort((a, b) => b.start.compareTo(a.start));
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): () {
          if (!saving) save();
        },
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
          if (!saving) save();
        },
      },
      child: Dialog(
        insetPadding: EdgeInsets.all(
          MediaQuery.sizeOf(context).width < 600 ? 12 : 32,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 720,
            maxHeight: MediaQuery.sizeOf(context).height - 48,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 14, 12, 4),
                child: Row(
                  children: [
                    Text(
                      task == null ? 'НОВАЯ ЗАДАЧА' : 'ЗАДАЧА',
                      style: const TextStyle(
                        letterSpacing: 2,
                        color: Palette.muted,
                        fontSize: 11,
                      ),
                    ),
                    const Spacer(),
                    if (task != null)
                      IconButton(
                        tooltip: 'Удалить задачу',
                        onPressed: saving
                            ? null
                            : () => guard(context, () async {
                                if (await deleteTask(context, ref, task) &&
                                    context.mounted) {
                                  Navigator.pop(context);
                                }
                              }),
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                    IconButton(
                      tooltip: 'Закрыть',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(26, 8, 26, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: title,
                        autofocus: task == null,
                        maxLines: null,
                        style: const TextStyle(
                          fontSize: 25,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -.5,
                        ),
                        decoration: const InputDecoration(
                          hintText: 'Что хотите сделать?',
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue:
                            repo.snapshot.projects.any((p) => p.id == projectId)
                            ? projectId
                            : '',
                        decoration: const InputDecoration(labelText: 'Проект'),
                        items: [
                          const DropdownMenuItem(
                            value: '',
                            child: Text('Без проекта'),
                          ),
                          ...repo.snapshot.projects.map(
                            (p) => DropdownMenuItem(
                              value: p.id,
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.circle,
                                    size: 9,
                                    color: Color(p.color),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(p.title),
                                ],
                              ),
                            ),
                          ),
                        ],
                        onChanged: (v) => setState(() => projectId = v ?? ''),
                      ),
                      const SizedBox(height: 16),
                      LiveMarkdownEditor(
                        value: description,
                        onChanged: (v) => description = v,
                        placeholder: 'Описание, ссылки, заметки по задаче…',
                      ),
                      if (task == null && start != null) ...[
                        const Divider(),
                        const SizedBox(height: 18),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            DateTimeButton(
                              label: 'С',
                              value: start!,
                              dateOnly: allDay,
                              onChanged: (v) => setState(() {
                                final duration = end!.difference(start!);
                                start = tz.TZDateTime(
                                  tz.getLocation(zone),
                                  v.year,
                                  v.month,
                                  v.day,
                                  v.hour,
                                  v.minute,
                                );
                                end = start!.add(duration);
                              }),
                            ),
                            DateTimeButton(
                              label: 'До',
                              value: end!,
                              dateOnly: allDay,
                              onChanged: (v) => setState(
                                () => end = tz.TZDateTime(
                                  tz.getLocation(zone),
                                  v.year,
                                  v.month,
                                  v.day,
                                  v.hour,
                                  v.minute,
                                ),
                              ),
                            ),
                          ],
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('На весь день'),
                          value: allDay,
                          onChanged: (v) => setState(() {
                            allDay = v;
                            if (v) {
                              final loc = tz.getLocation(zone);
                              start = tz.TZDateTime(
                                loc,
                                start!.year,
                                start!.month,
                                start!.day,
                              );
                              end = tz.TZDateTime(
                                loc,
                                start!.year,
                                start!.month,
                                start!.day + 1,
                              );
                            }
                          }),
                        ),
                        const SizedBox(height: 16),
                        RepeatPicker(
                          value: rule,
                          start: start!,
                          timezone: zone,
                          onChanged: (v) => setState(() => rule = v),
                        ),
                        const SizedBox(height: 16),
                        ReminderPicker(
                          values: reminders,
                          onChanged: (v) => setState(() => reminders = v),
                        ),
                      ],
                      if (task != null) ...[
                        const Divider(),
                        const SizedBox(height: 18),
                        Row(
                          children: [
                            const Text(
                              'План',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const Spacer(),
                            Text(
                              formatDuration(repo.snapshot.estimate(task.id)),
                              style: const TextStyle(color: Palette.blue),
                            ),
                            TextButton.icon(
                              onPressed: () => guard(context, () async {
                                final s = await pickDateTime(
                                  context,
                                  DateTime.now(),
                                );
                                if (s == null) return;
                                await repo.schedule(
                                  task,
                                  s,
                                  s.add(
                                    Duration(
                                      minutes:
                                          repo.snapshot.settings.defaultMinutes,
                                    ),
                                  ),
                                );
                              }),
                              icon: const Icon(Icons.add_rounded, size: 17),
                              label: const Text('Блок'),
                            ),
                          ],
                        ),
                        if (blocks.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          RepeatPicker(
                            value: rule,
                            start: blocks.first.start,
                            timezone: zone,
                            onChanged: (v) => setState(() => rule = v),
                          ),
                          if (rule != initialRule && task.seriesId.isNotEmpty)
                            const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: Text(
                                'Новая периодичность применяется с этой задачи. Выполненная работа сохраняется.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Palette.muted,
                                ),
                              ),
                            ),
                          const SizedBox(height: 12),
                        ],
                        for (final b in blocks)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            leading: Icon(
                              b.historical
                                  ? Icons.history_rounded
                                  : Icons.calendar_today_outlined,
                              size: 18,
                              color: Palette.muted,
                            ),
                            title: Text(
                              '${DateFormat('d MMM, HH:mm', 'ru').format(tz.TZDateTime.from(b.start, tz.getLocation(repo.snapshot.settings.timezone)))} — ${DateFormat('d MMM, HH:mm', 'ru').format(tz.TZDateTime.from(b.end, tz.getLocation(repo.snapshot.settings.timezone)))}',
                            ),
                            subtitle: Text(
                              b.historical
                                  ? 'История плана'
                                  : formatDuration(b.duration),
                            ),
                            onTap: () => editBlock(context, b),
                            trailing: PopupMenuButton<String>(
                              onSelected: (v) => guard(context, () async {
                                if (v == 'remove') await repo.unschedule(b);
                                if (v == 'split') {
                                  await repo.splitBlock(
                                    b,
                                    b.start.add(
                                      Duration(
                                        milliseconds:
                                            b.duration.inMilliseconds ~/ 2,
                                      ),
                                    ),
                                  );
                                }
                              }),
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                  value: 'split',
                                  child: Text('Разделить пополам'),
                                ),
                                const PopupMenuItem(
                                  value: 'remove',
                                  child: Text('Убрать из плана'),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 16),
                        const Divider(),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            const Text(
                              'Потраченное время',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const Spacer(),
                            Text(
                              formatDuration(
                                repo.snapshot.spent(task.id, repo.now()),
                              ),
                              style: const TextStyle(color: Palette.pink),
                            ),
                            IconButton(
                              tooltip: 'Добавить время вручную',
                              onPressed: () => editSession(context, task),
                              icon: const Icon(Icons.add_rounded),
                            ),
                          ],
                        ),
                        if (sessions.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 16),
                            child: Text(
                              'Рабочих сессий пока нет',
                              style: TextStyle(color: Palette.muted),
                            ),
                          ),
                        for (final s in sessions)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            leading: Icon(
                              s.running
                                  ? Icons.play_circle_outline_rounded
                                  : Icons.timelapse_rounded,
                              color: s.running ? Palette.pink : Palette.muted,
                              size: 20,
                            ),
                            title: Text(
                              '${DateFormat('d MMM, HH:mm', 'ru').format(tz.TZDateTime.from(s.start, tz.getLocation(repo.snapshot.settings.timezone)))} — ${s.end == null ? 'сейчас' : DateFormat('HH:mm').format(tz.TZDateTime.from(s.end!, tz.getLocation(repo.snapshot.settings.timezone)))}',
                            ),
                            subtitle: Text(
                              formatDuration(
                                (s.end ?? repo.now()).difference(s.start),
                              ),
                            ),
                            onTap: () => editSession(context, task, session: s),
                            trailing: IconButton(
                              tooltip: 'Удалить запись времени',
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                size: 18,
                              ),
                              onPressed: () =>
                                  guard(context, () => repo.discardSession(s)),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    if (task != null)
                      TextButton.icon(
                        onPressed: () => guard(context, () async {
                          await repo.status(
                            task,
                            task.done ? TaskStatus.todo : TaskStatus.done,
                          );
                          if (context.mounted) Navigator.pop(context);
                        }),
                        icon: Icon(
                          task.done ? Icons.undo_rounded : Icons.check_rounded,
                        ),
                        label: Text(
                          task.done ? 'Вернуть в работу' : 'Завершить',
                        ),
                      ),
                    const Spacer(),
                    FilledButton(
                      onPressed: saving ? null : save,
                      child: Text(saving ? 'Сохранение…' : 'Сохранить'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
