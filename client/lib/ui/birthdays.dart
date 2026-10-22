import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;
import '../domain/birthdays.dart';
import '../domain/models.dart';
import 'providers.dart';
import 'theme.dart';

const birthdayColor = Color(0xffa7c8b5);

Future<void> editBirthday(BuildContext context, {Birthday? birthday}) =>
    showDialog<void>(
      context: context,
      builder: (_) => BirthdayEditor(birthday: birthday),
    );

class BirthdayPage extends ConsumerWidget {
  const BirthdayPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(appProvider);
    final zone = tz.getLocation(repo.snapshot.settings.timezone);
    final now = repo.now();
    final list = [...repo.snapshot.birthdays]
      ..sort(
        (a, b) =>
            nextBirthday(a, now, zone).compareTo(nextBirthday(b, now, zone)),
      );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 848),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(0, 16, 0, 6),
                child: Text(
                  'Близкие люди — в календаре. Возраст посчитается автоматически.',
                  style: TextStyle(color: context.palette.muted, height: 1.5),
                ),
              ),
              Text(
                'Напоминание в день рождения · 09:00 · ${zone.name}',
                style: TextStyle(
                  color: context.palette.accent(birthdayColor),
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: list.isEmpty
                    ? const EmptyState(
                        icon: Icons.cake_outlined,
                        title: 'Важные даты всегда рядом',
                        subtitle: 'Нажмите + и укажите имя и дату рождения.',
                      )
                    : ListView.separated(
                        key: const ValueKey('birthday-people'),
                        itemCount: list.length,
                        separatorBuilder: (_, index) =>
                            const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final birthday = list[index];
                          final next = nextBirthday(birthday, now, zone);
                          final today = tz.TZDateTime.from(now, zone);
                          final isToday = dayKey(next) == dayKey(today);
                          return ListTile(
                            key: ValueKey('birthday-person-${birthday.id}'),
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 8,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            leading: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: context.palette.taskSurface(
                                  birthdayColor,
                                  subdued: !isToday,
                                ),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Icon(
                                Icons.cake_outlined,
                                color: context.palette.accent(birthdayColor),
                                size: 21,
                              ),
                            ),
                            title: Text(
                              birthday.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${isToday ? 'Сегодня' : DateFormat('d MMMM', 'ru').format(next)} · ${ageLabel(next.year - birthday.date.year)}',
                              style: TextStyle(
                                color: isToday
                                    ? context.palette.accent(birthdayColor)
                                    : context.palette.muted,
                                fontSize: 12,
                              ),
                            ),
                            trailing: const Icon(
                              Icons.chevron_right_rounded,
                              size: 18,
                            ),
                            onTap: () =>
                                editBirthday(context, birthday: birthday),
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
}

class BirthdayEditor extends ConsumerStatefulWidget {
  const BirthdayEditor({super.key, this.birthday});
  final Birthday? birthday;
  @override
  ConsumerState<BirthdayEditor> createState() => _BirthdayEditorState();
}

class _BirthdayEditorState extends ConsumerState<BirthdayEditor> {
  late final TextEditingController name, date;
  String? error;
  bool saving = false;
  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: widget.birthday?.name ?? '');
    date = TextEditingController(
      text: widget.birthday == null
          ? ''
          : DateFormat('dd.MM.yyyy').format(widget.birthday!.date),
    );
  }

  @override
  void dispose() {
    name.dispose();
    date.dispose();
    super.dispose();
  }

  DateTime? parsedDate() {
    try {
      return DateFormat('dd.MM.yyyy').parseStrict(date.text.trim());
    } on FormatException {
      return null;
    }
  }

  Future<void> save() async {
    if (saving) return;
    final birth = parsedDate();
    if (birth == null || name.text.trim().isEmpty) {
      setState(() => error = 'Введите имя и дату рождения: ДД.ММ.ГГГГ');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await BirthdayService(
        ref.read(appProvider),
      ).save(name.text, birth, birthday: widget.birthday);
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

  Future<void> remove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Удалить день рождения?'),
        content: const Text('Ежегодные записи и напоминания будут удалены.'),
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
    if (confirmed != true || !mounted) return;
    await guard(context, () async {
      await BirthdayService(ref.read(appProvider)).delete(widget.birthday!);
      if (mounted) Navigator.pop(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(appProvider), birth = parsedDate();
    final zone = tz.getLocation(repo.snapshot.settings.timezone);
    final today = tz.TZDateTime.from(repo.now(), zone);
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.cake_outlined,
            color: context.palette.accent(birthdayColor),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Text('День рождения')),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('birthday-name'),
                controller: name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Имя'),
              ),
              const SizedBox(height: 18),
              TextField(
                key: const ValueKey('birthday-date'),
                controller: date,
                keyboardType: TextInputType.datetime,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => save(),
                decoration: InputDecoration(
                  labelText: 'Дата рождения',
                  hintText: 'ДД.ММ.ГГГГ',
                  suffixIcon: IconButton(
                    tooltip: 'Выбрать дату',
                    icon: const Icon(Icons.calendar_month_outlined, size: 19),
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate:
                            birth != null &&
                                !birth.isAfter(today) &&
                                birth.year >= 1800
                            ? birth
                            : DateTime(today.year - 30, today.month, today.day),
                        firstDate: DateTime(1800),
                        lastDate: DateTime(today.year, today.month, today.day),
                        initialDatePickerMode: DatePickerMode.year,
                      );
                      if (picked != null && mounted) {
                        setState(
                          () => date.text = DateFormat(
                            'dd.MM.yyyy',
                          ).format(picked),
                        );
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: context.palette
                      .accent(birthdayColor)
                      .withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.text.trim().isEmpty
                          ? 'Каждый год — важный день'
                          : name.text.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.palette.accent(birthdayColor),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (birth != null &&
                        birth.year >= 1800 &&
                        !birth.isAfter(today)) ...[
                      const SizedBox(height: 5),
                      Text(
                        '${DateFormat('d MMMM', 'ru').format(birth)} · ${ageLabel(today.year - birth.year)} в этом году',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.palette.muted,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    const Text(
                      'Напомним в день рождения',
                      style: TextStyle(fontSize: 12, height: 1.5),
                    ),
                    Text(
                      'В 09:00 · ${repo.snapshot.settings.timezone}',
                      style: TextStyle(
                        fontSize: 11,
                        color: context.palette.muted,
                      ),
                    ),
                    if (birth?.month == 2 && birth?.day == 29)
                      Text(
                        'В невисокосный год — 28 февраля',
                        style: TextStyle(
                          fontSize: 11,
                          color: context.palette.muted,
                        ),
                      ),
                  ],
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.birthday != null)
          TextButton(
            onPressed: saving ? null : remove,
            child: const Text('Удалить'),
          ),
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const ValueKey('save-birthday'),
          onPressed: saving ? null : save,
          child: const Text('Готово'),
        ),
      ],
    );
  }
}

class BirthdayChip extends ConsumerWidget {
  const BirthdayChip({super.key, required this.task, this.compact = false});
  final Task task;
  final bool compact;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(appProvider);
    final birthday = repo.snapshot.birthdays
        .where((b) => b.id == task.seriesId)
        .firstOrNull;
    final label = birthday == null
        ? task.title
        : '${birthday.name} · ${ageLabel((task.entity.data['birthday_year'] as int) - birthday.date.year)}';
    return Tooltip(
      message: task.title,
      child: Material(
        color: task.done
            ? context.palette.raised
            : Theme.of(context).brightness == Brightness.dark
            ? const Color(0xff2c4439)
            : context.palette.taskSurface(birthdayColor, selected: true),
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: () => showBirthday(context, task),
          child: SizedBox(
            height: compact ? 27 : 34,
            child: Row(
              children: [
                const SizedBox(width: 7),
                if (!compact) ...[
                  Icon(
                    Icons.cake_outlined,
                    size: 15,
                    color: context.palette.accent(birthdayColor),
                  ),
                  const SizedBox(width: 7),
                ],
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 10 : 12,
                      color: task.done
                          ? context.palette.muted
                          : context.palette.accent(birthdayColor),
                      decoration: task.done ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ),
                SizedBox(
                  width: compact ? 24 : 32,
                  child: IconButton(
                    key: ValueKey('birthday-complete-${task.id}'),
                    padding: EdgeInsets.zero,
                    tooltip: task.done ? 'Вернуть отметку' : 'Поздравил',
                    onPressed: () => guard(
                      context,
                      () => repo.status(
                        task,
                        task.done ? TaskStatus.todo : TaskStatus.done,
                      ),
                    ),
                    icon: Icon(
                      task.done
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      size: 17,
                      color: context.palette.accent(birthdayColor),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showBirthday(BuildContext parentContext, Task task) =>
    showDialog<void>(
      context: parentContext,
      builder: (c) => Consumer(
        builder: (context, ref, _) {
          final repo = ref.watch(appProvider);
          final current = repo.snapshot.task(task.id);
          final birthday = repo.snapshot.birthdays
              .where((b) => b.id == task.seriesId)
              .firstOrNull;
          return AlertDialog(
            title: Text(birthday?.name ?? task.title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.cake_outlined,
                  color: context.palette.accent(birthdayColor),
                  size: 42,
                ),
                const SizedBox(height: 18),
                if (current != null)
                  Text(current.title, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                if (current != null)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: current.done,
                    title: const Text('Поздравил'),
                    onChanged: (_) => guard(
                      context,
                      () => repo.status(
                        current,
                        current.done ? TaskStatus.todo : TaskStatus.done,
                      ),
                    ),
                  ),
              ],
            ),
            actions: [
              if (birthday != null)
                TextButton(
                  onPressed: () async {
                    Navigator.pop(c);
                    await editBirthday(parentContext, birthday: birthday);
                  },
                  child: const Text('Изменить'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Закрыть'),
              ),
            ],
          );
        },
      ),
    );
