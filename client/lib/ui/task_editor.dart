import '../l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;
import '../domain/models.dart';
import '../domain/recurrence.dart';
import '../data/repository.dart';
import 'markdown_editor.dart';
import 'providers.dart';
import 'schedule_fields.dart';
import 'theme.dart';
import 'birthdays.dart';
import 'session_editor.dart';
export 'session_editor.dart' show SessionEditor;

Future<void> openTask(
  BuildContext context, {
  Task? task,
  DateTime? start,
  DateTime? end,
  String? blockId,
}) => task?.isBirthday == true
    ? showBirthday(context, task!)
    : showDialog<void>(
        context: context,
        builder: (_) => TaskEditor(
          taskId: task?.id,
          start: start,
          end: end,
          blockId: blockId,
        ),
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
      '$label ${DateFormat(dateOnly ? 'd MMM y' : 'd MMM, HH:mm', AppLocale.language).format(value)}',
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

Future<void> editBlock(BuildContext context, TimeBlock block) =>
    showDialog<void>(
      context: context,
      builder: (_) => BlockEditor(block: block),
    );

Future<RepeatScope?> chooseScope(BuildContext context, {String? title}) =>
    showDialog<RepeatScope>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text(title ?? tr("Изменить повторение")),
        children: [
          for (final scope in RepeatScope.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, scope),
              child: Text(
                scope == RepeatScope.instance
                    ? tr("Только эту задачу")
                    : scope == RepeatScope.following
                    ? tr("Эту и последующие")
                    : tr("Всю серию"),
              ),
            ),
        ],
      ),
    );

Future<bool> deleteTask(BuildContext context, WidgetRef ref, Task task) async {
  RepeatScope? scope;
  if (task.seriesId.isNotEmpty) {
    scope = await chooseScope(
      context,
      title: tr("Удалить повторяющуюся задачу"),
    );
  } else {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr("Удалить задачу?")),
        content: Text(
          tr("«{0}» и её записи времени будут удалены на всех устройствах.", [
            task.title,
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(tr("Отмена")),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(tr("Удалить")),
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

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr("Календарный блок")),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ScheduleFields(
              start: start,
              end: end,
              allDay: allDay,
              timezone: zone,
              onChanged: (s, e, day) => setState(() {
                start = s;
                end = e;
                allDay = day;
              }),
            ),
            const SizedBox(height: 8),
            ReminderPicker(
              values: reminders,
              onChanged: (v) => setState(() => reminders = v),
            ),
            const SizedBox(height: 12),
            Text(
              tr("План: {0}", [formatDuration(end.difference(start))]),
              style: TextStyle(color: context.palette.muted),
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
        child: Text(tr("Сохранить")),
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
      decoration: InputDecoration(labelText: tr("Часовой пояс IANA")),
      onSubmitted: (v) {
        try {
          tz.getLocation(v);
          onChanged(v);
        } catch (e) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr("Выберите часовой пояс из списка"))),
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
    title: Text(tr("Напомнить заранее")),
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
              decoration: InputDecoration(
                labelText: tr("За"),
                errorText: error,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<int>(
              key: const ValueKey('reminder-unit'),
              initialValue: unit,
              items: [
                DropdownMenuItem(value: 1, child: Text(tr("минут"))),
                DropdownMenuItem(value: 60, child: Text(tr("часов"))),
                DropdownMenuItem(value: 1440, child: Text(tr("дней"))),
                DropdownMenuItem(value: 10080, child: Text(tr("недель"))),
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
        child: Text(tr("Отмена")),
      ),
      FilledButton(
        onPressed: () {
          final n = int.tryParse(amount.text);
          if (n == null || n < 0 || n * unit > 525600) {
            setState(() => error = tr("От 0 до {0}", [525600 ~/ unit]));
          } else {
            Navigator.pop(context, n * unit);
          }
        },
        child: Text(tr("Добавить")),
      ),
    ],
  );
}

String reminderLabel(int minutes) => minutes == 0
    ? tr("В начале события")
    : minutes >= 10080 && minutes % 10080 == 0
    ? tr("За {0} нед.", [minutes ~/ 10080])
    : minutes >= 1440 && minutes % 1440 == 0
    ? tr("За {0} дн.", [minutes ~/ 1440])
    : minutes >= 60 && minutes % 60 == 0
    ? tr("За {0} ч", [minutes ~/ 60])
    : tr("За {0} мин", [minutes]);

class ReminderPicker extends StatelessWidget {
  const ReminderPicker({
    super.key,
    required this.values,
    required this.onChanged,
  });
  final List<int> values;
  final ValueChanged<List<int>> onChanged;

  Future<void> select(BuildContext context, int index, int value) async {
    if (value == -2) {
      final custom = await showDialog<int>(
        context: context,
        builder: (_) => const ReminderOffsetEditor(),
      );
      if (custom == null || !context.mounted) return;
      value = custom;
    }
    final next = [...values];
    if (index < next.length) next.removeAt(index);
    if (value >= 0) next.insert(index.clamp(0, next.length), value);
    onChanged(next.toSet().toList());
  }

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: EdgeInsets.only(top: 12, right: 16),
        child: Icon(
          Icons.notifications_none_rounded,
          size: 20,
          color: context.palette.muted,
        ),
      ),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < (values.isEmpty ? 1 : values.length); i++)
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        key: ValueKey('reminder-choice-$i'),
                        isExpanded: true,
                        value: values.isEmpty ? -1 : values[i],
                        style: TextStyle(
                          fontFamily: 'Inter',
                          color: context.palette.text,
                          fontSize: 13,
                        ),
                        items: [
                          DropdownMenuItem(
                            value: -1,
                            child: Text(tr("Без напоминания")),
                          ),
                          for (final v in {
                            0,
                            5,
                            10,
                            15,
                            30,
                            60,
                            1440,
                            10080,
                            ...values,
                          })
                            DropdownMenuItem(
                              value: v,
                              child: Text(reminderLabel(v)),
                            ),
                          DropdownMenuItem(
                            value: -2,
                            child: Text(tr("Другое…")),
                          ),
                        ],
                        onChanged: (value) {
                          if (value != null) select(context, i, value);
                        },
                      ),
                    ),
                  ),
                  if (values.length > 1)
                    IconButton(
                      tooltip: tr("Удалить напоминание"),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () => onChanged([...values]..removeAt(i)),
                    ),
                ],
              ),
            if (values.isNotEmpty && values.length < 12)
              TextButton(
                onPressed: () => select(context, values.length, -2),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 32),
                ),
                child: Text(
                  tr("Добавить напоминание"),
                  style: TextStyle(fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

class TaskEditor extends ConsumerStatefulWidget {
  const TaskEditor({
    super.key,
    this.taskId,
    this.start,
    this.end,
    this.blockId,
  });
  final String? taskId, blockId;
  final DateTime? start, end;
  @override
  ConsumerState<TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends ConsumerState<TaskEditor> {
  final title = TextEditingController();
  final descriptionKey = GlobalKey<LiveMarkdownEditorState>();
  final projectScroll = ScrollController();
  final selectedProjectKey = GlobalKey();
  String description = '',
      projectId = '',
      rule = '',
      initialRule = '',
      zone = 'UTC';
  DateTime? start, end;
  TimeBlock? originalBlock;
  bool allDay = false, saving = false;
  List<int> reminders = [];

  @override
  void initState() {
    super.initState();
    final repo = ref.read(appProvider);
    final task = repo.snapshot.task(widget.taskId ?? '');
    title.text = (task?.title ?? '').replaceAll(RegExp(r'[\r\n]+'), ' ');
    description = task?.description ?? '';
    projectId = task?.projectId ?? '';
    if (task != null) {
      final blocks = repo.snapshot.taskBlocks(task.id);
      originalBlock =
          blocks.where((b) => b.id == widget.blockId).firstOrNull ??
          blocks.where((b) => !b.historical).firstOrNull ??
          blocks.firstOrNull;
      initialRule =
          repo.snapshot.entities
                  .where((e) => e.id == task.seriesId)
                  .firstOrNull
                  ?.data['rule']
              as String? ??
          '';
      rule = initialRule;
    }
    zone = repo.snapshot.settings.timezone;
    start = originalBlock?.start ?? widget.start;
    end =
        originalBlock?.end ??
        widget.end ??
        start?.add(Duration(minutes: repo.snapshot.settings.defaultMinutes));
    if (start != null) start = tz.TZDateTime.from(start!, tz.getLocation(zone));
    if (end != null) end = tz.TZDateTime.from(end!, tz.getLocation(zone));
    allDay = originalBlock?.allDay ?? false;
    reminders = [
      ...originalBlock?.reminders ?? repo.snapshot.settings.reminders,
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !projectScroll.hasClients) return;
      final target = selectedProjectKey.currentContext?.findRenderObject();
      if (target != null) {
        projectScroll.position.ensureVisible(target, alignment: .5);
      }
    });
  }

  @override
  void dispose() {
    title.dispose();
    projectScroll.dispose();
    super.dispose();
  }

  bool get timingChanged => originalBlock == null
      ? start != null
      : !originalBlock!.start.isAtSameMomentAs(start!) ||
            !originalBlock!.end.isAtSameMomentAs(end!) ||
            originalBlock!.allDay != allDay ||
            !listEquals(originalBlock!.reminders, reminders);

  Future<void> save() => guard(context, () async {
    if (title.text.trim().isEmpty) throw ArgumentError(tr("Введите название"));
    if (start != null) Repository.validateInterval(start!, end!);
    if (rule.isNotEmpty) RecurrenceService.parse(rule);
    setState(() => saving = true);
    try {
      final repo = ref.read(appProvider);
      var task = repo.snapshot.task(widget.taskId ?? '');
      if (widget.taskId != null && task == null) {
        throw StateError(tr("Задача уже удалена"));
      }
      final recurrence = RecurrenceService(repo);
      if (task == null) {
        task = await repo.createTask(
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
          await recurrence.create(
            task,
            repo.snapshot.taskBlocks(task.id).first,
            rule,
          );
        }
      } else {
        final metadataChanged =
            title.text.trim() != task.title ||
            description != task.description ||
            projectId != task.projectId;
        final ruleChanged = rule != initialRule;
        var scope = RepeatScope.instance;
        if (task.seriesId.isNotEmpty &&
            !ruleChanged &&
            (metadataChanged || timingChanged)) {
          final selected = await chooseScope(context);
          if (selected == null || !mounted) return;
          scope = selected;
        }
        if (metadataChanged) {
          await recurrence.edit(
            task,
            scope,
            title: title.text.trim(),
            description: description,
            projectId: projectId,
          );
        }
        task = repo.snapshot.task(task.id)!;
        if (timingChanged && start != null) {
          if (originalBlock == null) {
            await repo.schedule(
              task,
              start!,
              end!,
              allDay: allDay,
              reminders: reminders,
              timezone: zone,
            );
          } else {
            final current = repo.snapshot.blocks
                .where((b) => b.id == originalBlock!.id)
                .firstOrNull;
            if (current == null) throw StateError(tr("Этот блок уже удалён"));
            await recurrence.editTiming(
              current,
              metadataChanged && scope == RepeatScope.following
                  ? RepeatScope.series
                  : scope,
              start!,
              end!,
              timezone: zone,
              allDay: allDay,
              reminders: reminders,
            );
          }
        }
        if (ruleChanged) {
          await recurrence.changeRuleFrom(
            repo.snapshot.task(task.id)!,
            rule,
            blockId: originalBlock?.id,
          );
        }
      }
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  });

  void planNow() => setState(() {
    final repo = ref.read(appProvider);
    start = tz.TZDateTime.from(repo.now(), tz.getLocation(zone));
    start = tz.TZDateTime(
      tz.getLocation(zone),
      start!.year,
      start!.month,
      start!.day,
      start!.hour,
      start!.minute,
    );
    end = start!.add(Duration(minutes: repo.snapshot.settings.defaultMinutes));
  });

  void loadBlock(TimeBlock? block) => setState(() {
    originalBlock = block;
    start = block == null
        ? null
        : tz.TZDateTime.from(block.start, tz.getLocation(zone));
    end = block == null
        ? null
        : tz.TZDateTime.from(block.end, tz.getLocation(zone));
    if (block != null) {
      reminders = [...block.reminders];
      allDay = block.allDay;
    }
  });

  Widget disclosure(
    String key,
    String label,
    IconData icon,
    List<Widget> children, {
    bool expanded = false,
    String? subtitle,
  }) => ExpansionTile(
    key: ValueKey(key),
    initiallyExpanded: expanded,
    maintainState: true,
    tilePadding: EdgeInsets.zero,
    childrenPadding: const EdgeInsets.only(bottom: 12),
    shape: const Border(),
    collapsedShape: const Border(),
    leading: Icon(icon, size: 20, color: context.palette.muted),
    title: Text(label, style: const TextStyle(fontSize: 13)),
    subtitle: subtitle == null
        ? null
        : Text(
            subtitle,
            style: TextStyle(fontSize: 11, color: context.palette.muted),
          ),
    children: children,
  );

  String dateLabel(DateTime value) => DateFormat(
    'd MMM, HH:mm',
    AppLocale.language,
  ).format(tz.TZDateTime.from(value, tz.getLocation(zone)));

  Widget projectTags(Repository repo) {
    final activeId = repo.snapshot.projects.any((p) => p.id == projectId)
        ? projectId
        : '';
    Widget tag(String id, String title, Color color) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Tooltip(
        key: activeId == id ? selectedProjectKey : null,
        message: title,
        child: ChoiceChip(
          key: ValueKey('task-project-$id'),
          selected: activeId == id,
          showCheckmark: false,
          avatar: Icon(
            id.isEmpty ? Icons.folder_outlined : Icons.circle,
            size: id.isEmpty ? 16 : 9,
            color: color,
          ),
          label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 170),
            child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          labelStyle: TextStyle(
            fontSize: 13,
            color: activeId == id ? color : context.palette.muted,
          ),
          backgroundColor: context.palette.surface,
          selectedColor: color.withValues(alpha: .14),
          side: BorderSide(
            color: activeId == id
                ? color.withValues(alpha: .5)
                : context.palette.border,
          ),
          shape: const StadiumBorder(),
          onSelected: saving ? null : (_) => setState(() => projectId = id),
        ),
      ),
    );
    return SingleChildScrollView(
      key: const ValueKey('task-projects'),
      controller: projectScroll,
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          tag('', tr("Без проекта"), context.accentColor),
          for (final project in repo.snapshot.projects)
            tag(
              project.id,
              project.title,
              context.palette.accent(Color(project.color)),
            ),
        ],
      ),
    );
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
          if (!saving) descriptionKey.currentState?.focusEditor();
        },
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
          if (!saving) descriptionKey.currentState?.focusEditor();
        },
      },
      child: Dialog(
        insetPadding: EdgeInsets.all(
          MediaQuery.sizeOf(context).width < 600 ? 12 : 32,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 600,
            maxHeight: MediaQuery.sizeOf(context).height - 48,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 12, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('task-title'),
                        controller: title,
                        autofocus: task == null,
                        maxLines: 1,
                        textInputAction: TextInputAction.done,
                        inputFormatters: [
                          FilteringTextInputFormatter.deny(
                            RegExp(r'[\r\n]+'),
                            replacementString: ' ',
                          ),
                        ],
                        onEditingComplete: () {},
                        onSubmitted: (_) {
                          if (!saving && title.text.trim().isNotEmpty) save();
                        },
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w500,
                          letterSpacing: -.4,
                        ),
                        decoration: InputDecoration(
                          hintText: tr("Введите название"),
                          filled: false,
                          border: UnderlineInputBorder(
                            borderSide: BorderSide(
                              color: context.palette.border,
                            ),
                          ),
                          enabledBorder: UnderlineInputBorder(
                            borderSide: BorderSide(
                              color: context.palette.border,
                            ),
                          ),
                          focusedBorder: UnderlineInputBorder(
                            borderSide: BorderSide(
                              color: context.accentColor,
                              width: 2,
                            ),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 12,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: tr("Закрыть"),
                      onPressed: saving ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded, size: 20),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (start != null) ...[
                        ScheduleFields(
                          start: start!,
                          end: end!,
                          allDay: allDay,
                          timezone: zone,
                          rule: rule,
                          onChanged: (s, e, day) => setState(() {
                            start = s;
                            end = e;
                            allDay = day;
                          }),
                          onRuleChanged: (v) => setState(() => rule = v),
                        ),
                        if (rule != initialRule &&
                            task?.seriesId.isNotEmpty == true)
                          Padding(
                            padding: EdgeInsets.only(left: 32, top: 4),
                            child: Text(
                              tr("Новая периодичность — с этой задачи."),
                              style: TextStyle(
                                color: context.palette.muted,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        ReminderPicker(
                          values: reminders,
                          onChanged: (v) => setState(() => reminders = v),
                        ),
                      ] else
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: planNow,
                            icon: const Icon(Icons.schedule_rounded, size: 20),
                            label: Text(tr("Запланировать")),
                          ),
                        ),
                      const SizedBox(height: 4),
                      projectTags(repo),
                      if (task != null) ...[
                        disclosure(
                          'task-blocks',
                          tr("Блоки в календаре"),
                          Icons.view_agenda_outlined,
                          [
                            for (final b in blocks)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                title: Text(
                                  '${dateLabel(b.start)} — ${dateLabel(b.end)}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                subtitle: Text(
                                  b.historical
                                      ? tr("История плана")
                                      : formatDuration(b.duration),
                                ),
                                onTap: () async {
                                  await editBlock(context, b);
                                  if (!mounted || b.id != originalBlock?.id) {
                                    return;
                                  }
                                  final updated = ref
                                      .read(appProvider)
                                      .snapshot
                                      .blocks
                                      .where((v) => v.id == b.id)
                                      .firstOrNull;
                                  if (updated != null) loadBlock(updated);
                                },
                                trailing: PopupMenuButton<String>(
                                  onSelected: (v) => guard(context, () async {
                                    if (v == 'remove') {
                                      await repo.unschedule(b);
                                      if (mounted &&
                                          b.id == originalBlock?.id) {
                                        loadBlock(
                                          repo.snapshot
                                              .taskBlocks(task.id)
                                              .firstOrNull,
                                        );
                                      }
                                    } else {
                                      await repo.splitBlock(
                                        b,
                                        b.start.add(
                                          Duration(
                                            milliseconds:
                                                b.duration.inMilliseconds ~/ 2,
                                          ),
                                        ),
                                      );
                                      if (mounted &&
                                          b.id == originalBlock?.id) {
                                        loadBlock(
                                          repo.snapshot.blocks.firstWhere(
                                            (v) => v.id == b.id,
                                          ),
                                        );
                                      }
                                    }
                                  }),
                                  itemBuilder: (_) => [
                                    PopupMenuItem(
                                      value: 'split',
                                      child: Text(tr("Разделить пополам")),
                                    ),
                                    PopupMenuItem(
                                      value: 'remove',
                                      child: Text(tr("Убрать из плана")),
                                    ),
                                  ],
                                ),
                              ),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: () => guard(context, () async {
                                  final value = await pickDateTime(
                                    context,
                                    tz.TZDateTime.from(
                                      repo.now(),
                                      tz.getLocation(zone),
                                    ),
                                  );
                                  if (value == null) return;
                                  final at = tz.TZDateTime(
                                    tz.getLocation(zone),
                                    value.year,
                                    value.month,
                                    value.day,
                                    value.hour,
                                    value.minute,
                                  );
                                  await repo.schedule(
                                    task,
                                    at,
                                    at.add(
                                      Duration(
                                        minutes: repo
                                            .snapshot
                                            .settings
                                            .defaultMinutes,
                                      ),
                                    ),
                                  );
                                  if (mounted && originalBlock == null) {
                                    loadBlock(
                                      repo.snapshot.taskBlocks(task.id).last,
                                    );
                                  }
                                }),
                                icon: const Icon(Icons.add_rounded, size: 18),
                                label: Text(tr("Добавить блок")),
                              ),
                            ),
                          ],
                          subtitle:
                              '${blocks.length} · ${formatDuration(repo.snapshot.estimate(task.id))}',
                        ),
                        disclosure(
                          'task-sessions',
                          tr("Потраченное время"),
                          Icons.timelapse_rounded,
                          [
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                key: const ValueKey('add-work-session'),
                                onPressed: () => editSession(context, task),
                                icon: const Icon(Icons.add_rounded, size: 18),
                                label: Text(tr("Добавить время вручную")),
                              ),
                            ),
                            for (final s in sessions)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                title: Text(
                                  '${dateLabel(s.start)} — ${s.end == null ? tr("сейчас") : dateLabel(s.end!)}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                subtitle: Text(
                                  formatDuration(
                                    (s.end ?? repo.now()).difference(s.start),
                                  ),
                                ),
                                onTap: () =>
                                    editSession(context, task, session: s),
                                trailing: IconButton(
                                  tooltip: tr("Удалить запись времени"),
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    size: 18,
                                  ),
                                  onPressed: () => guard(
                                    context,
                                    () => repo.discardSession(s),
                                  ),
                                ),
                              ),
                          ],
                          subtitle: formatDuration(
                            repo.snapshot.spent(task.id, repo.now()),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      const Divider(),
                      LiveMarkdownEditor(
                        key: descriptionKey,
                        value: description,
                        onChanged: (v) => description = v,
                        toolbarLabel: tr("Описание"),
                        placeholder: tr("Описание, ссылки, заметки по задаче…"),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    if (task != null) ...[
                      IconButton(
                        tooltip: tr("Удалить задачу"),
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 20,
                        ),
                        onPressed: saving
                            ? null
                            : () => guard(context, () async {
                                if (await deleteTask(context, ref, task) &&
                                    context.mounted) {
                                  Navigator.pop(context);
                                }
                              }),
                      ),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: saving
                                ? null
                                : () => guard(context, () async {
                                    await repo.status(
                                      task,
                                      task.done
                                          ? TaskStatus.todo
                                          : TaskStatus.done,
                                    );
                                    if (context.mounted) Navigator.pop(context);
                                  }),
                            child: Text(
                              task.done ? tr("Вернуть") : tr("Завершить"),
                            ),
                          ),
                        ),
                      ),
                    ] else
                      const Spacer(),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: saving ? null : save,
                      child: Text(saving ? tr("Сохранение…") : tr("Сохранить")),
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
