import '../l10n/strings.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../domain/ical.dart';
import '../domain/models.dart';
import '../domain/recurrence.dart';
import 'providers.dart';
import 'task_editor.dart';
import 'theme.dart';
import 'birthdays.dart';
import 'server_settings.dart';
import 'encryption_settings.dart';
import 'statistics.dart';
import 'workday_settings.dart';
import 'calendar_zoom.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, required this.onOpenBirthdays});
  final VoidCallback onOpenBirthdays;
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController minutes;
  late String zone;
  late List<int> reminders;
  int? pendingAccentColor;
  int? pendingSearchTypos;
  late int defaultMinutes;
  String? minutesError, saveError;
  int saveVersion = 0;
  bool savingSettings = false;
  @override
  void initState() {
    super.initState();
    final repo = ref.read(appProvider);
    minutes = TextEditingController(
      text: '${repo.snapshot.settings.defaultMinutes}',
    );
    zone = repo.snapshot.settings.timezone;
    reminders = [...repo.snapshot.settings.reminders];
    defaultMinutes = repo.snapshot.settings.defaultMinutes;
  }

  Future<void> saveSettings({int? accentColor, int? searchTypos}) async {
    if (accentColor != null) pendingAccentColor = accentColor;
    if (searchTypos != null) pendingSearchTypos = searchTypos;
    final version = ++saveVersion;
    setState(() {
      savingSettings = true;
      saveError = null;
    });
    try {
      await ref
          .read(appProvider)
          .updateSettings(
            defaultMinutes,
            [...reminders],
            zone,
            accentColor: pendingAccentColor,
            searchTypos: pendingSearchTypos,
          );
      if (version == saveVersion) {
        pendingAccentColor = null;
        pendingSearchTypos = null;
      }
    } catch (error) {
      if (mounted && version == saveVersion) {
        setState(
          () => saveError = tr("Не удалось сохранить настройки: {0}", [error]),
        );
      }
    } finally {
      if (mounted && version == saveVersion) {
        setState(() => savingSettings = false);
      }
    }
  }

  void changeMinutes(String value) {
    final parsed = int.tryParse(value);
    final valid = parsed != null && parsed >= 5 && parsed <= 1440;
    setState(
      () => minutesError = valid ? null : tr("Введите от 5 до 1440 минут"),
    );
    if (valid) {
      defaultMinutes = parsed;
      saveSettings();
    }
  }

  @override
  void dispose() {
    for (final c in [minutes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> projectDialog({Project? project}) async {
    final text = TextEditingController(text: project?.title ?? '');
    var color = project?.color ?? context.accentColor.toARGB32();
    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(project == null ? tr("Новый проект") : tr("Проект")),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: text,
                  autofocus: true,
                  decoration: InputDecoration(labelText: tr("Название")),
                ),
                const SizedBox(height: 16),
                ColorPalettePicker(
                  value: color,
                  onChanged: (v) => set(() => color = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: Text(tr("Отмена")),
            ),
            FilledButton(
              onPressed: () => guard(c, () async {
                await ref
                    .read(appProvider)
                    .saveProject(text.text, color, project: project);
                if (c.mounted) Navigator.pop(c);
              }),
              child: Text(tr("Сохранить")),
            ),
          ],
        ),
      ),
    );
    text.dispose();
  }

  Future<void> importFile() async {
    final selected = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['ics'],
    );
    if (selected == null || selected.files.single.path == null) return;
    if (!mounted) return;
    await guard(context, () async {
      final file = File(selected.files.single.path!);
      if (await file.length() > 20 * 1024 * 1024) {
        throw ArgumentError(tr("Файл календаря превышает 20 МБ"));
      }
      final repo = ref.read(appProvider);
      final parsed = parseCalendar(
        await file.readAsString(),
        repo.snapshot.settings.timezone,
      );
      String project = '';
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => StatefulBuilder(
          builder: (c, set) => AlertDialog(
            title: Text(tr("Импорт календаря")),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr(
                        "Готово к импорту: {0} событий. Уже импортированные записи будут пропущены.",
                        [parsed.events.length],
                      ),
                    ),
                    const SizedBox(height: 18),
                    DropdownButtonFormField<String>(
                      initialValue: project,
                      decoration: InputDecoration(
                        labelText: tr("Проект для календаря"),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: '',
                          child: Text(tr("Без проекта")),
                        ),
                        ...repo.snapshot.projects.map(
                          (p) => DropdownMenuItem(
                            value: p.id,
                            child: Text(p.title),
                          ),
                        ),
                      ],
                      onChanged: (v) => set(() => project = v ?? ''),
                    ),
                    const SizedBox(height: 16),
                    for (final e in parsed.events.take(10))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          '${DateFormat('d MMM y', AppLocale.language).format(e.start.toLocal())} · ${e.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (parsed.events.length > 10)
                      Text(tr("И ещё {0}…", [parsed.events.length - 10])),
                    if (parsed.warnings.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        tr("Требуют внимания ({0})", [parsed.warnings.length]),
                        style: TextStyle(color: Theme.of(c).colorScheme.error),
                      ),
                      ...parsed.warnings.map(
                        (w) => Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(w, style: const TextStyle(fontSize: 12)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: Text(tr("Отмена")),
              ),
              FilledButton(
                onPressed: parsed.events.isEmpty
                    ? null
                    : () => guard(c, () async {
                        final count = await importCalendar(
                          repo,
                          parsed,
                          project,
                        );
                        await RecurrenceService(repo).expand(
                          repo.now(),
                          repo.now().add(const Duration(days: 90)),
                        );
                        await repo.rollover();
                        if (c.mounted) {
                          final messenger = ScaffoldMessenger.of(c);
                          Navigator.pop(c);
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(tr("Импортировано: {0}", [count])),
                            ),
                          );
                        }
                      }),
                child: Text(tr("Импортировать")),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget section(String title, Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Card(
      child: Padding(
        padding: EdgeInsets.all(
          MediaQuery.sizeOf(context).width < 330 ? 10 : 24,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 20),
            child,
          ],
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(appProvider),
        notifications = ref.read(remindersProvider);
    final tracking = ref.watch(systemTrackingProvider);
    return ListView(
      padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 330 ? 10 : 24),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Card(
                    child: ListTile(
                      key: const ValueKey('open-statistics'),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 8,
                      ),
                      leading: Icon(
                        Icons.insights_rounded,
                        color: context.accentColor,
                      ),
                      title: Text(tr("Статистика")),
                      subtitle: Text(tr("План, факт и привычки")),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const StatisticsPage(),
                        ),
                      ),
                    ),
                  ),
                ),
                section(
                  tr("Оформление"),
                  Column(
                    children: [
                      SwitchListTile.adaptive(
                        key: const ValueKey('light-theme-toggle'),
                        activeTrackColor: context.accentColor,
                        applyCupertinoTheme: true,
                        contentPadding: EdgeInsets.zero,
                        secondary: Icon(
                          repo.lightTheme
                              ? Icons.light_mode_outlined
                              : Icons.dark_mode_outlined,
                          color: context.accentColor,
                        ),
                        title: Text(tr("Светлая тема")),
                        subtitle: Text(tr("Сохраняется на этом устройстве")),
                        value: repo.lightTheme,
                        onChanged: (value) =>
                            guard(context, () => repo.setLightTheme(value)),
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<double>(
                        key: const ValueKey('interface-scale'),
                        initialValue: repo.interfaceScale,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: tr("Масштаб интерфейса"),
                        ),
                        items: [
                          for (final value in [.5, .7, 1.0, 1.5, 2.0])
                            DropdownMenuItem(
                              value: value,
                              child: Text('${(value * 100).round()}%'),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            guard(context, () => repo.setInterfaceScale(value));
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        key: const ValueKey('app-language'),
                        initialValue: repo.language,
                        isExpanded: true,
                        decoration: InputDecoration(labelText: tr("Язык")),
                        items: [
                          for (final entry in const {
                            'ru': 'Русский',
                            'en': 'English',
                            'es': 'Español',
                            'de': 'Deutsch',
                            'zh': '中文',
                            'hi': 'हिन्दी',
                          }.entries)
                            DropdownMenuItem(
                              value: entry.key,
                              child: Text(entry.value),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            guard(context, () => repo.setLanguage(value));
                          }
                        },
                      ),
                    ],
                  ),
                ),
                section(
                  tr("Планирование"),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const CalendarZoomSetting(),
                      const SizedBox(height: 20),
                      TextField(
                        key: const ValueKey('default-minutes'),
                        controller: minutes,
                        keyboardType: TextInputType.number,
                        onChanged: changeMinutes,
                        decoration: InputDecoration(
                          labelText: tr("Длительность нового блока"),
                          suffixText: tr("минут"),
                          errorText: minutesError,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TimezoneField(
                        value: zone,
                        onChanged: (v) {
                          setState(() => zone = v);
                          saveSettings();
                        },
                      ),
                      const SizedBox(height: 18),
                      ReminderPicker(
                        values: reminders,
                        onChanged: (v) {
                          setState(() => reminders = v);
                          saveSettings();
                        },
                      ),
                      const SizedBox(height: 20),
                      Text(tr("Акцентный цвет")),
                      const SizedBox(height: 10),
                      ColorPalettePicker(
                        key: const ValueKey('accent-color-picker'),
                        value:
                            pendingAccentColor ??
                            repo.snapshot.settings.accentColor,
                        onChanged: (v) => saveSettings(accentColor: v),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        tr(
                          "Логотип, кнопки, выделения, акцентный текст и задачи без проекта. У проектов — собственные цвета.",
                        ),
                        style: TextStyle(
                          color: context.palette.muted,
                          fontSize: 12,
                        ),
                      ),
                      if (Platform.isIOS)
                        Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Text(
                            tr(
                              "Иконка приложения тоже меняет цвет. iOS покажет системное уведомление.",
                            ),
                            style: TextStyle(
                              color: context.palette.muted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      if (ref.watch(appIconProvider)?.error case final error?)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 8),
                            Text(
                              error,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                                fontSize: 12,
                              ),
                            ),
                            TextButton(
                              onPressed: ref.read(appIconProvider)?.retry,
                              child: Text(tr("Повторить смену иконки")),
                            ),
                          ],
                        ),
                      const SizedBox(height: 12),
                      const Divider(),
                      const SizedBox(height: 12),
                      Text(tr("Точность поиска")),
                      const SizedBox(height: 10),
                      SegmentedButton<int>(
                        key: const ValueKey('search-typos'),
                        segments: [
                          ButtonSegment(value: 0, label: Text(tr("Точно"))),
                          ButtonSegment(value: 1, label: Text(tr("1 ошибка"))),
                          ButtonSegment(value: 2, label: Text(tr("2 ошибки"))),
                        ],
                        selected: {
                          pendingSearchTypos ??
                              repo.snapshot.settings.searchTypos,
                        },
                        showSelectedIcon: false,
                        onSelectionChanged: (values) =>
                            saveSettings(searchTypos: values.single),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        tr(
                          "Одна буква ищется точно, для двух букв допускается не больше одной ошибки. Дописывать слово не нужно. Сначала идут заметки, затем события; в каждой группе — заголовки, потом текст. Точные совпадения первыми внутри группы.",
                        ),
                        style: TextStyle(
                          color: context.palette.muted,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        saveError ??
                            (savingSettings
                                ? tr("Сохраняется…")
                                : tr("Изменения сохраняются автоматически")),
                        style: TextStyle(
                          color: saveError == null
                              ? context.palette.muted
                              : Theme.of(context).colorScheme.error,
                          fontSize: 12,
                        ),
                      ),
                      if (saveError != null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: saveSettings,
                            child: Text(tr("Повторить")),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Card(
                    child: ListTile(
                      key: const ValueKey('open-birthdays'),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      leading: Icon(
                        Icons.cake_outlined,
                        color: context.palette.accent(birthdayColor),
                      ),
                      title: Text(tr("Дни рождения")),
                      subtitle: Text(
                        repo.snapshot.birthdays.isEmpty
                            ? tr("Имена, даты и ежегодные напоминания")
                            : tr("Людей в списке: {0}", [
                                repo.snapshot.birthdays.length,
                              ]),
                        style: TextStyle(
                          color: context.palette.muted,
                          fontSize: 12,
                        ),
                      ),
                      trailing: const Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                      ),
                      onTap: widget.onOpenBirthdays,
                    ),
                  ),
                ),
                section(tr("Рабочий день"), const WorkdaySettings()),
                section(
                  tr("Проекты"),
                  Column(
                    children: [
                      for (final project in repo.snapshot.projects)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            Icons.circle,
                            size: 12,
                            color: context.palette.accent(Color(project.color)),
                          ),
                          title: Text(project.title),
                          onTap: () => projectDialog(project: project),
                          trailing: IconButton(
                            tooltip: tr("Удалить проект"),
                            onPressed: () => guard(context, () async {
                              final yes = await showDialog<bool>(
                                context: context,
                                builder: (c) => AlertDialog(
                                  title: Text(tr("Удалить проект?")),
                                  content: Text(
                                    tr(
                                      "Задачи сохранятся и станут задачами без проекта.",
                                    ),
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
                              if (yes == true) {
                                await repo.deleteProject(project);
                              }
                            }),
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 18,
                            ),
                          ),
                        ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: projectDialog,
                          icon: const Icon(Icons.add_rounded),
                          label: Text(tr("Создать проект")),
                        ),
                      ),
                    ],
                  ),
                ),
                section(
                  tr("Уведомления на этом устройстве"),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr(
                          "Разрешите уведомления на каждом устройстве. Ближайшие 60 напоминаний о синхронизированных задачах сохраняются в системе и работают без интернета. При открытии приложения список обновляется.",
                        ),
                        style: TextStyle(color: context.palette.muted),
                      ),
                      if (Platform.isLinux)
                        Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: Text(
                            tr(
                              "Для доставки после закрытия приложения установите фоновую службу из пакета Linux.",
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      Text(
                        notifications.permissionGranted == false
                            ? tr(
                                "Уведомления выключены. Разрешите их в системных настройках для Yggvion.",
                              )
                            : notifications.permissionGranted == true
                            ? tr("Разрешены · запланировано {0}", [
                                notifications.scheduledCount,
                              ])
                            : tr("Проверьте разрешение на этом устройстве"),
                        style: TextStyle(
                          color: notifications.permissionGranted == false
                              ? context.palette.pink
                              : context.palette.green,
                        ),
                      ),
                      if (tracking?.error != null)
                        Text(
                          tracking!.error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      if (notifications.error != null)
                        Text(
                          notifications.error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed: () =>
                            guard(context, notifications.openSettings),
                        icon: const Icon(Icons.notifications_active_outlined),
                        label: Text(tr("Разрешить уведомления")),
                      ),
                      const SizedBox(height: 10),
                      TextButton.icon(
                        onPressed: () => guard(context, () async {
                          await notifications.testNotification();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  tr("Тестовое уведомление через 10 секунд"),
                                ),
                              ),
                            );
                          }
                        }),
                        icon: const Icon(Icons.notification_add_outlined),
                        label: Text(tr("Проверить уведомление")),
                      ),
                    ],
                  ),
                ),
                section(
                  tr("Подключение"),
                  Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.sync_rounded),
                        title: Text(tr("Синхронизация")),
                        subtitle: Text(tr(repo.syncStatus)),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => const SynchronizationPage(),
                          ),
                        ),
                      ),
                      ListTile(
                        leading: const Icon(Icons.lock_outline_rounded),
                        title: Text(tr("Шифрование")),
                        subtitle: Text(
                          tr("Пароль для синхронизации и резервных копий"),
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => const EncryptionPage(),
                          ),
                        ),
                      ),
                      ListTile(
                        leading: const Icon(Icons.backup_outlined),
                        title: Text(tr("Резервное копирование")),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => const BackupsPage(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                section(
                  tr("Перенос данных"),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: importFile,
                      icon: const Icon(Icons.file_download_outlined),
                      label: Text(tr("Импорт Google Calendar (.ics)")),
                    ),
                  ),
                ),
                if (repo.conflictCount > 0 ||
                    sessionConflicts(
                      repo.snapshot.sessions,
                      repo.now(),
                    ).isNotEmpty)
                  section(
                    tr("Конфликты между устройствами"),
                    const ConflictsPanel(),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class ConflictsPanel extends ConsumerWidget {
  const ConflictsPanel({super.key});

  String describe(Map record, Snapshot snapshot) {
    if (record['deleted'] == true) return tr("Запись удалена");
    final data = record['data'] as Map;
    final labels = {
      'title': tr("Название"),
      'description': tr("Описание"),
      'content': tr("Текст"),
      'status': tr("Статус"),
      'project_id': tr("Проект"),
      'task_id': tr("Задача"),
      'start': tr("Начало"),
      'end': tr("Конец"),
      'at': tr("Напомнить"),
      'timezone': tr("Часовой пояс"),
      'all_day': tr("На весь день"),
      'default_minutes': tr("Блок по умолчанию, мин"),
      'reminders': tr("Напоминания, мин до начала"),
      'task_color': tr("Акцентный цвет"),
      'search_typos': tr("Допуск опечаток"),
    };
    return labels.entries
        .where((e) => data.containsKey(e.key))
        .map((e) {
          var value = '${data[e.key] ?? tr("сейчас")}';
          if (['start', 'end', 'at'].contains(e.key) && data[e.key] != null) {
            value = DateFormat(
              'dd.MM.yyyy HH:mm',
            ).format(parseTime(data[e.key]).toLocal());
          } else if (e.key == 'status') {
            value = TaskStatus.parse(value).label;
          } else if (e.key == 'project_id') {
            value = snapshot.project(value)?.title ?? tr("Без проекта");
          } else if (e.key == 'task_id') {
            value = snapshot.task(value)?.title ?? tr("Удалённая задача");
          } else if (e.key == 'all_day') {
            value = data[e.key] == true ? tr("Да") : tr("Нет");
          } else if (e.key == 'task_color') {
            final color = data[e.key] as int? ?? AppSettings.defaultAccentColor;
            final index = Palette.projects.indexWhere(
              (c) => c.toARGB32() == color,
            );
            value = index >= 0
                ? Palette.projectNames[index]
                : '#${(color & 0xffffff).toRadixString(16).padLeft(6, '0')}';
          }
          return '${e.value}: $value';
        })
        .join('\n\n');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(appProvider);
    final timeConflicts = sessionConflicts(repo.snapshot.sessions, repo.now());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final conflict in timeConflicts)
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr("Пересекающееся потраченное время"),
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  for (final s in conflict.sessions)
                    Text(
                      tr("Устройство {0}{1} · {2}\n{3} — {4}", [
                        conflict.devices.toList().indexOf(s.deviceId) + 1,
                        s.deviceId == repo.deviceId ? tr(" (это)") : '',
                        repo.snapshot.task(s.taskId)?.title ?? tr("Задача"),
                        DateFormat('dd.MM HH:mm').format(s.start.toLocal()),
                        s.end == null
                            ? tr("сейчас")
                            : DateFormat('HH:mm').format(s.end!.toLocal()),
                      ]),
                      style: TextStyle(
                        fontSize: 12,
                        color: context.palette.muted,
                      ),
                    ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final device in conflict.devices)
                        OutlinedButton(
                          onPressed: () => guard(
                            context,
                            () => repo.resolveSessions(conflict, device),
                          ),
                          child: Text(
                            tr("Устройство {0}", [
                              conflict.devices.toList().indexOf(device) + 1,
                            ]),
                          ),
                        ),
                      FilledButton.tonal(
                        onPressed: () => guard(
                          context,
                          () => repo.resolveSessions(conflict, null),
                        ),
                        child: Text(tr("Объединить")),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        FutureBuilder<List<Map<String, dynamic>>>(
          future: repo.conflicts(),
          builder: (context, snapshot) => Column(
            children: [
              for (final c in snapshot.data ?? [])
                Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          (c['local'] as Map)['data']['title'] as String? ??
                              tr("Изменения записи"),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 10),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: Text(
                            tr("Сравнить версии"),
                            style: TextStyle(fontSize: 13),
                          ),
                          children: [
                            SelectableText(
                              tr(
                                "На этом устройстве\n\n{0}\n\nСинхронизированная версия\n\n{1}",
                                [
                                  describe(c['local'] as Map, repo.snapshot),
                                  describe(c['remote'] as Map, repo.snapshot),
                                ],
                              ),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            TextButton(
                              onPressed: () => guard(
                                context,
                                () => repo.resolveRecordConflict(
                                  c['id'] as String,
                                  keepLocal: true,
                                ),
                              ),
                              child: Text(tr("Оставить мою")),
                            ),
                            TextButton(
                              onPressed: () => guard(
                                context,
                                () => repo.resolveRecordConflict(
                                  c['id'] as String,
                                  keepLocal: false,
                                ),
                              ),
                              child: Text(tr("С сервера")),
                            ),
                            if ((c['local'] as Map)['kind'] == 'note')
                              FilledButton.tonal(
                                onPressed: () => guard(
                                  context,
                                  () => repo.resolveRecordConflict(
                                    c['id'] as String,
                                    keepLocal: false,
                                    keepBoth: true,
                                  ),
                                ),
                                child: Text(tr("Сохранить обе")),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
