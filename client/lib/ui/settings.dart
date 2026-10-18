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

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController minutes, url, name, key;
  late String zone;
  late List<int> reminders;
  bool connecting = false;
  @override
  void initState() {
    super.initState();
    final repo = ref.read(appProvider);
    minutes = TextEditingController(
      text: '${repo.snapshot.settings.defaultMinutes}',
    );
    url = TextEditingController(text: ref.read(syncProvider).url ?? '');
    name = TextEditingController(text: repo.deviceName);
    key = TextEditingController();
    zone = repo.snapshot.settings.timezone;
    reminders = [...repo.snapshot.settings.reminders];
  }

  @override
  void dispose() {
    for (final c in [minutes, url, name, key]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> projectDialog({Project? project}) async {
    final text = TextEditingController(text: project?.title ?? '');
    var color = project?.color ?? Palette.blue.toARGB32();
    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(project == null ? 'Новый проект' : 'Проект'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: text,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Название'),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  children: Palette.projects
                      .map(
                        (p) => InkWell(
                          onTap: () => set(() => color = p.toARGB32()),
                          borderRadius: BorderRadius.circular(20),
                          child: CircleAvatar(
                            radius: 17,
                            backgroundColor: p,
                            child: color == p.toARGB32()
                                ? const Icon(
                                    Icons.check_rounded,
                                    size: 18,
                                    color: Palette.background,
                                  )
                                : null,
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => guard(c, () async {
                await ref
                    .read(appProvider)
                    .saveProject(text.text, color, project: project);
                if (c.mounted) Navigator.pop(c);
              }),
              child: const Text('Сохранить'),
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
        throw ArgumentError('Файл календаря превышает 20 МБ');
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
            title: const Text('Импорт календаря'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Готово к импорту: ${parsed.events.length} событий. Уже импортированные записи будут пропущены.',
                    ),
                    const SizedBox(height: 18),
                    DropdownButtonFormField<String>(
                      initialValue: project,
                      decoration: const InputDecoration(
                        labelText: 'Проект для календаря',
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('Без проекта'),
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
                          '${DateFormat('d MMM y', 'ru').format(e.start.toLocal())} · ${e.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (parsed.events.length > 10)
                      Text('И ещё ${parsed.events.length - 10}…'),
                    if (parsed.warnings.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        'Требуют внимания (${parsed.warnings.length})',
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
                child: const Text('Отмена'),
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
                            SnackBar(content: Text('Импортировано: $count')),
                          );
                        }
                      }),
                child: const Text('Импортировать'),
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
        padding: const EdgeInsets.all(24),
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
        sync = ref.read(syncProvider),
        notifications = ref.read(remindersProvider);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                section(
                  'Планирование',
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: minutes,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Длительность нового блока',
                          suffixText: 'минут',
                        ),
                      ),
                      const SizedBox(height: 16),
                      TimezoneField(value: zone, onChanged: (v) => zone = v),
                      const SizedBox(height: 18),
                      ReminderPicker(
                        values: reminders,
                        onChanged: (v) => setState(() => reminders = v),
                      ),
                      const SizedBox(height: 20),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton(
                          onPressed: () => guard(context, () async {
                            await repo.updateSettings(
                              int.tryParse(minutes.text) ?? 0,
                              reminders,
                              zone,
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Настройки сохранены'),
                                ),
                              );
                            }
                          }),
                          child: const Text('Сохранить настройки'),
                        ),
                      ),
                    ],
                  ),
                ),
                section(
                  'Проекты',
                  Column(
                    children: [
                      for (final project in repo.snapshot.projects)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            Icons.circle,
                            size: 12,
                            color: Color(project.color),
                          ),
                          title: Text(project.title),
                          onTap: () => projectDialog(project: project),
                          trailing: IconButton(
                            tooltip: 'Удалить проект',
                            onPressed: () => guard(context, () async {
                              final yes = await showDialog<bool>(
                                context: context,
                                builder: (c) => AlertDialog(
                                  title: const Text('Удалить проект?'),
                                  content: const Text(
                                    'Задачи сохранятся и станут задачами без проекта.',
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
                          label: const Text('Создать проект'),
                        ),
                      ),
                    ],
                  ),
                ),
                section(
                  'Уведомления на этом устройстве',
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Разрешите уведомления на каждом устройстве. Ближайшие 60 напоминаний о синхронизированных задачах сохраняются в системе и работают без интернета. При открытии приложения список обновляется.',
                        style: TextStyle(color: Palette.muted),
                      ),
                      if (Platform.isLinux)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: Text(
                            'Для доставки после закрытия приложения установите фоновую службу из пакета Linux.',
                          ),
                        ),
                      const SizedBox(height: 12),
                      Text(
                        notifications.permissionGranted == false
                            ? 'Уведомления выключены. Разрешите их в системных настройках для Yggvion.'
                            : notifications.permissionGranted == true
                            ? 'Разрешены · запланировано ${notifications.scheduledCount}'
                            : 'Проверьте разрешение на этом устройстве',
                        style: TextStyle(
                          color: notifications.permissionGranted == false
                              ? Palette.pink
                              : Palette.green,
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
                            guard(context, notifications.requestPermission),
                        icon: const Icon(Icons.notifications_active_outlined),
                        label: const Text('Разрешить уведомления'),
                      ),
                      const SizedBox(height: 10),
                      TextButton.icon(
                        onPressed: () => guard(context, () async {
                          await notifications.testNotification();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Тестовое уведомление через 10 секунд',
                                ),
                              ),
                            );
                          }
                        }),
                        icon: const Icon(Icons.notification_add_outlined),
                        label: const Text('Проверить уведомление'),
                      ),
                    ],
                  ),
                ),
                section(
                  'Синхронизация с VPS',
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        repo.syncStatus,
                        style: const TextStyle(color: Palette.blue),
                      ),
                      if (repo.syncError != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            repo.syncError!,
                            style: const TextStyle(color: Palette.muted),
                          ),
                        ),
                      const SizedBox(height: 18),
                      TextField(
                        controller: url,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: 'Адрес сервера',
                          hintText: 'https://planner.example.com',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: name,
                        decoration: const InputDecoration(
                          labelText: 'Название устройства',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: key,
                        obscureText: true,
                        enableSuggestions: false,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Ключ подключения',
                        ),
                      ),
                      const SizedBox(height: 18),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          FilledButton(
                            onPressed: connecting
                                ? null
                                : () => guard(context, () async {
                                    setState(() => connecting = true);
                                    try {
                                      await sync.pair(
                                        url.text,
                                        key.text,
                                        name.text,
                                      );
                                      key.clear();
                                    } finally {
                                      if (mounted) {
                                        setState(() => connecting = false);
                                      }
                                    }
                                  }),
                            child: Text(
                              connecting
                                  ? 'Подключение…'
                                  : 'Подключить устройство',
                            ),
                          ),
                          OutlinedButton(
                            onPressed: sync.connected
                                ? () => guard(context, sync.sync)
                                : null,
                            child: const Text('Синхронизировать'),
                          ),
                        ],
                      ),
                      if (sync.connected) ...[
                        const SizedBox(height: 18),
                        FutureBuilder<List<Map<String, dynamic>>>(
                          future: sync.devices(),
                          builder: (context, snapshot) {
                            if (snapshot.hasError) {
                              return const Text(
                                'Не удалось получить список устройств',
                              );
                            }
                            return Column(
                              children: [
                                for (final d in snapshot.data ?? [])
                                  ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(
                                      Icons.devices_rounded,
                                      size: 20,
                                    ),
                                    title: Text(d['name'] as String),
                                    subtitle: d['id'] == repo.deviceId
                                        ? const Text('Это устройство')
                                        : null,
                                    trailing: d['id'] != repo.deviceId
                                        ? TextButton(
                                            onPressed: () =>
                                                guard(context, () async {
                                                  await sync.revoke(
                                                    d['id'] as String,
                                                  );
                                                  if (mounted) setState(() {});
                                                }),
                                            child: const Text('Отозвать'),
                                          )
                                        : null,
                                  ),
                              ],
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
                section(
                  'Перенос данных',
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: importFile,
                      icon: const Icon(Icons.file_download_outlined),
                      label: const Text('Импорт Google Calendar (.ics)'),
                    ),
                  ),
                ),
                if (repo.conflictCount > 0 ||
                    sessionConflicts(
                      repo.snapshot.sessions,
                      repo.now(),
                    ).isNotEmpty)
                  section(
                    'Конфликты между устройствами',
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
    if (record['deleted'] == true) return 'Запись удалена';
    final data = record['data'] as Map;
    const labels = {
      'title': 'Название',
      'description': 'Описание',
      'content': 'Текст',
      'status': 'Статус',
      'project_id': 'Проект',
      'task_id': 'Задача',
      'start': 'Начало',
      'end': 'Конец',
      'at': 'Напомнить',
      'timezone': 'Часовой пояс',
      'all_day': 'На весь день',
      'default_minutes': 'Блок по умолчанию, мин',
      'reminders': 'Напоминания, мин до начала',
    };
    return labels.entries
        .where((e) => data.containsKey(e.key))
        .map((e) {
          var value = '${data[e.key] ?? 'сейчас'}';
          if (['start', 'end', 'at'].contains(e.key) && data[e.key] != null) {
            value = DateFormat(
              'dd.MM.yyyy HH:mm',
            ).format(parseTime(data[e.key]).toLocal());
          } else if (e.key == 'status') {
            value = TaskStatus.parse(value).label;
          } else if (e.key == 'project_id') {
            value = snapshot.project(value)?.title ?? 'Без проекта';
          } else if (e.key == 'task_id') {
            value = snapshot.task(value)?.title ?? 'Удалённая задача';
          } else if (e.key == 'all_day') {
            value = data[e.key] == true ? 'Да' : 'Нет';
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
                  const Text(
                    'Пересекающееся потраченное время',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  for (final s in conflict.sessions)
                    Text(
                      'Устройство ${conflict.devices.toList().indexOf(s.deviceId) + 1}${s.deviceId == repo.deviceId ? ' (это)' : ''} · ${repo.snapshot.task(s.taskId)?.title ?? 'Задача'}\n${DateFormat('dd.MM HH:mm').format(s.start.toLocal())} — ${s.end == null ? 'сейчас' : DateFormat('HH:mm').format(s.end!.toLocal())}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Palette.muted,
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
                            'Устройство ${conflict.devices.toList().indexOf(device) + 1}',
                          ),
                        ),
                      FilledButton.tonal(
                        onPressed: () => guard(
                          context,
                          () => repo.resolveSessions(conflict, null),
                        ),
                        child: const Text('Объединить'),
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
                              'Изменения записи',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 10),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: const Text(
                            'Сравнить версии',
                            style: TextStyle(fontSize: 13),
                          ),
                          children: [
                            SelectableText(
                              'На этом устройстве\n\n${describe(c['local'] as Map, repo.snapshot)}\n\nСинхронизированная версия\n\n${describe(c['remote'] as Map, repo.snapshot)}',
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
                              child: const Text('Оставить мою'),
                            ),
                            TextButton(
                              onPressed: () => guard(
                                context,
                                () => repo.resolveRecordConflict(
                                  c['id'] as String,
                                  keepLocal: false,
                                ),
                              ),
                              child: const Text('С сервера'),
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
                                child: const Text('Сохранить обе'),
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
