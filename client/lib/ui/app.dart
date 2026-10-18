import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;
import '../data/repository.dart';
import '../domain/models.dart';
import '../domain/recurrence.dart';
import 'calendar.dart';
import 'dashboard.dart';
import 'shortcuts.dart';
import 'timer_control.dart';
import 'notes.dart';
import 'providers.dart';
import 'settings.dart';
import 'task_card.dart';
import 'task_editor.dart';
import 'theme.dart';

class YggvionApp extends StatelessWidget {
  const YggvionApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Yggvion',
    debugShowCheckedModeBanner: false,
    theme: appTheme(),
    locale: const Locale('ru'),
    supportedLocales: const [Locale('ru'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: const Workspace(),
  );
}

enum PageKind { today, planner, board, notes, settings }

class Workspace extends ConsumerStatefulWidget {
  const Workspace({super.key});
  @override
  ConsumerState<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends ConsumerState<Workspace>
    with WidgetsBindingObserver {
  PageKind page = PageKind.today;
  String projectId = '', query = '';
  Task? selected;
  String? selectedNote;
  DateTime? calendarDate;
  Timer? ticker;
  bool mobileTasks = true;
  String? runtimeError;
  static const labels = [
    'Сегодня',
    'Планировщик',
    'Канбан',
    'Заметки',
    'Настройки',
  ];
  static const icons = [
    Icons.wb_sunny_outlined,
    Icons.calendar_month_outlined,
    Icons.view_kanban_outlined,
    Icons.description_outlined,
    Icons.tune_rounded,
  ];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ticker = Timer.periodic(const Duration(seconds: 30), (_) => refresh());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final reminders = ref.read(remindersProvider);
      reminders.onOpenTask = _openReminder;
      final pending = reminders.pendingTaskId;
      reminders.pendingTaskId = null;
      if (pending != null) _openReminder(pending);
      refresh();
      unawaited(guard(context, reminders.requestPermissionOnce));
    });
  }

  void _openReminder(String taskId) {
    if (!mounted) return;
    final task = ref.read(appProvider).snapshot.task(taskId);
    if (task != null) unawaited(openTask(context, task: task));
  }

  Future<void> refresh() async {
    try {
      final repo = ref.read(appProvider);
      await repo.rollover();
      await RecurrenceService(repo).expand(
        repo.now().subtract(const Duration(days: 1)),
        repo.now().add(const Duration(days: 90)),
      );
      if (mounted) setState(() => runtimeError = null);
    } catch (e) {
      if (mounted) {
        setState(() => runtimeError = 'Не удалось обновить календарь: $e');
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      unawaited(ref.read(remindersProvider).refresh());
    }
    if (state == AppLifecycleState.resumed) {
      refresh();
      ref.read(syncProvider).sync();
      unawaited(guard(context, ref.read(remindersProvider).checkPermission));
      ref.read(remindersProvider).refresh();
    }
  }

  @override
  void dispose() {
    ticker?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void go(PageKind next) {
    setState(() {
      page = next;
      selected = null;
    });
  }

  Future<void> search() async {
    final result = await showDialog<Entity>(
      context: context,
      builder: (_) => const SearchDialog(),
    );
    if (result == null || !mounted) return;
    if (result.kind == 'note') {
      setState(() {
        page = PageKind.notes;
        selectedNote = result.id;
      });
    } else if (result.kind == 'task') {
      await openTask(context, task: Task(result));
    } else if (result.kind == 'series') {
      setState(() {
        page = PageKind.planner;
        calendarDate = parseTime(result.data['start']).toLocal();
      });
    }
  }

  Future<void> createNote() => guard(context, () async {
    final note = await ref.read(appProvider).createNote();
    if (!mounted) return;
    setState(() {
      page = PageKind.notes;
      selectedNote = note.id;
    });
  });

  Widget projectFilter() {
    final repo = ref.watch(appProvider);
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: repo.snapshot.projects.any((p) => p.id == projectId)
            ? projectId
            : '',
        isDense: true,
        style: const TextStyle(
          fontSize: 12,
          color: Palette.muted,
          fontFamily: 'Inter',
        ),
        borderRadius: BorderRadius.circular(12),
        items: [
          const DropdownMenuItem(value: '', child: Text('Все проекты')),
          ...repo.snapshot.projects.map(
            (p) => DropdownMenuItem(value: p.id, child: Text(p.title)),
          ),
        ],
        onChanged: (v) => setState(() => projectId = v ?? ''),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(appProvider), size = MediaQuery.sizeOf(context);
    final desktop = size.width >= 1000;
    final conflicts =
        repo.conflictCount +
        sessionConflicts(repo.snapshot.sessions, repo.now()).length;
    return CallbackShortcuts(
      bindings: {
        for (final meta in [true, false]) ...{
          SingleActivator(LogicalKeyboardKey.keyF, meta: meta, control: !meta):
              search,
          SingleActivator(LogicalKeyboardKey.keyK, meta: meta, control: !meta):
              search,
          SingleActivator(
            LogicalKeyboardKey.keyN,
            meta: meta,
            control: !meta,
          ): () =>
              openTask(context),
          SingleActivator(
            LogicalKeyboardKey.keyN,
            meta: meta,
            control: !meta,
            shift: true,
          ): createNote,
          SingleActivator(
            LogicalKeyboardKey.comma,
            meta: meta,
            control: !meta,
          ): () =>
              go(PageKind.settings),
          SingleActivator(
            LogicalKeyboardKey.space,
            meta: meta,
            control: !meta,
            shift: true,
          ): () =>
              toggleLastCalendarTimer(context, ref),
          for (var i = 0; i < 5; i++)
            SingleActivator(
              [
                LogicalKeyboardKey.digit1,
                LogicalKeyboardKey.digit2,
                LogicalKeyboardKey.digit3,
                LogicalKeyboardKey.digit4,
                LogicalKeyboardKey.digit5,
              ][i],
              meta: meta,
              control: !meta,
            ): () =>
                go(PageKind.values[i]),
        },
        const SingleActivator(LogicalKeyboardKey.f1): () =>
            showShortcutHelp(context),
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (selected != null) setState(() => selected = null);
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: SafeArea(
            child: Row(
              children: [
                if (desktop) _sidebar(repo, conflicts),
                Expanded(
                  child: Column(
                    children: [
                      Container(
                        height: desktop ? 78 : 68,
                        padding: EdgeInsets.symmetric(
                          horizontal: desktop ? 30 : 16,
                        ),
                        child: Row(
                          children: [
                            if (!desktop && page == PageKind.settings)
                              IconButton(
                                onPressed: () => go(PageKind.today),
                                icon: const Icon(Icons.arrow_back_rounded),
                              ),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    labels[page.index],
                                    style: TextStyle(
                                      fontSize: desktop ? 26 : 22,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: -.8,
                                    ),
                                  ),
                                  if (desktop)
                                    Text(
                                      page == PageKind.today
                                          ? DateFormat(
                                              'EEEE, d MMMM',
                                              'ru',
                                            ).format(
                                              tz.TZDateTime.from(
                                                repo.now(),
                                                tz.getLocation(
                                                  repo
                                                      .snapshot
                                                      .settings
                                                      .timezone,
                                                ),
                                              ),
                                            )
                                          : page == PageKind.planner
                                          ? 'Найдите время для важного'
                                          : page == PageKind.board
                                          ? 'От идеи до завершения'
                                          : page == PageKind.notes
                                          ? 'Место для мыслей и знаний'
                                          : 'Ваше рабочее пространство',
                                      style: const TextStyle(
                                        color: Palette.muted,
                                        fontSize: 12,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            if (desktop &&
                                page != PageKind.settings &&
                                page != PageKind.notes)
                              projectFilter(),
                            if (!desktop &&
                                repo.snapshot.projects.isNotEmpty &&
                                page != PageKind.settings &&
                                page != PageKind.notes)
                              PopupMenuButton<String>(
                                tooltip: 'Фильтр проектов',
                                icon: Icon(
                                  Icons.filter_list_rounded,
                                  color: projectId.isEmpty
                                      ? Palette.muted
                                      : Palette.blue,
                                ),
                                onSelected: (v) =>
                                    setState(() => projectId = v),
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                    value: '',
                                    child: Text('Все проекты'),
                                  ),
                                  for (final p in repo.snapshot.projects)
                                    PopupMenuItem(
                                      value: p.id,
                                      child: Text(p.title),
                                    ),
                                ],
                              ),
                            const SizedBox(width: 8),
                            TimerControl(
                              compact: !desktop || size.width < 1280,
                            ),
                            IconButton(
                              tooltip: 'Поиск · ⌘F / Ctrl+F',
                              onPressed: search,
                              icon: const Icon(Icons.search_rounded),
                            ),
                            if (!desktop)
                              IconButton(
                                tooltip: 'Настройки',
                                onPressed: () => go(PageKind.settings),
                                icon: const Icon(Icons.tune_rounded),
                              ),
                            if (desktop && page != PageKind.settings)
                              Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: OutlinedButton.icon(
                                  onPressed: createNote,
                                  icon: const Icon(
                                    Icons.note_add_outlined,
                                    size: 17,
                                  ),
                                  label: const Text('Заметка'),
                                ),
                              ),
                            if (desktop && page != PageKind.settings)
                              Padding(
                                padding: const EdgeInsets.only(left: 12),
                                child: FilledButton.icon(
                                  onPressed: () => openTask(context),
                                  icon: const Icon(Icons.add_rounded, size: 18),
                                  label: const Text('Задача'),
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (runtimeError != null)
                        MaterialBanner(
                          content: Text(runtimeError!),
                          actions: [
                            TextButton(
                              onPressed: refresh,
                              child: const Text('Повторить'),
                            ),
                          ],
                        ),
                      if (conflicts > 0 && page != PageKind.settings)
                        InkWell(
                          onTap: () => go(PageKind.settings),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 9,
                            ),
                            color: Palette.pink.withValues(alpha: .1),
                            child: Text(
                              'Есть изменения с разных устройств ($conflicts) · Выбрать или объединить',
                              style: const TextStyle(
                                color: Palette.pink,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      Expanded(
                        child: switch (page) {
                          PageKind.today => _today(desktop),
                          PageKind.planner => _planner(desktop),
                          PageKind.board => _board(),
                          PageKind.notes => NotesPage(
                            key: ValueKey(selectedNote),
                            initialId: selectedNote,
                          ),
                          PageKind.settings => const SettingsPage(),
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: desktop
              ? null
              : NavigationBar(
                  height: 68,
                  selectedIndex: page == PageKind.settings ? 0 : page.index,
                  onDestinationSelected: (i) => go(PageKind.values[i]),
                  destinations: [
                    for (var i = 0; i < 4; i++)
                      NavigationDestination(
                        icon: Icon(icons[i]),
                        label: labels[i],
                      ),
                  ],
                ),
          floatingActionButton: desktop || page == PageKind.settings
              ? null
              : PopupMenuButton<String>(
                  tooltip: 'Создать',
                  onSelected: (v) => guard(context, () async {
                    if (v == 'task') {
                      await openTask(context);
                    } else {
                      final note = await repo.createNote();
                      setState(() {
                        page = PageKind.notes;
                        selectedNote = note.id;
                      });
                    }
                  }),
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'note',
                      child: ListTile(
                        leading: Icon(Icons.note_add_outlined),
                        title: Text('Заметка'),
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'task',
                      child: ListTile(
                        leading: Icon(Icons.add_task_rounded),
                        title: Text('Незапланированная задача'),
                      ),
                    ),
                  ],
                  child: Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: Palette.blue,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: .25),
                          blurRadius: 20,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.add_rounded,
                      color: Palette.background,
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _sidebar(Repository repo, int conflicts) => Container(
    width: 215,
    decoration: const BoxDecoration(
      color: Palette.surface,
      border: Border(right: BorderSide(color: Palette.border, width: .6)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 30, 24, 34),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: Palette.blue.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.spa_outlined,
                  color: Palette.blue,
                  size: 21,
                ),
              ),
              const SizedBox(width: 11),
              const Expanded(
                child: Text(
                  'yggvion',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -.9,
                  ),
                ),
              ),
            ],
          ),
        ),
        for (var i = 0; i < 4; i++)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
            child: ListTile(
              dense: true,
              selected: page.index == i,
              selectedColor: Palette.blue,
              selectedTileColor: Palette.blue.withValues(alpha: .09),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              leading: Icon(icons[i], size: 20),
              title: Text(
                labels[i],
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              onTap: () => go(PageKind.values[i]),
            ),
          ),
        const SizedBox(height: 30),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 26),
          child: Text(
            'ПРОЕКТЫ',
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 1.7,
              color: Palette.muted,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            children: [
              for (final p in repo.snapshot.projects)
                ListTile(
                  dense: true,
                  leading: Icon(Icons.circle, size: 8, color: Color(p.color)),
                  title: Text(
                    p.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  selected: projectId == p.id,
                  onTap: () =>
                      setState(() => projectId = projectId == p.id ? '' : p.id),
                ),
              if (repo.snapshot.projects.isEmpty)
                TextButton.icon(
                  onPressed: () => go(PageKind.settings),
                  icon: const Icon(Icons.add_rounded, size: 14),
                  label: const Text(
                    'Добавить проект',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              ListTile(
                dense: true,
                leading: const Icon(Icons.tune_rounded, size: 19),
                title: const Text('Настройки', style: TextStyle(fontSize: 13)),
                trailing: conflicts > 0
                    ? Badge(label: Text('$conflicts'))
                    : null,
                onTap: () => go(PageKind.settings),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.keyboard_outlined, size: 19),
                horizontalTitleGap: 10,
                minLeadingWidth: 20,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                title: const Text('Клавиши', style: TextStyle(fontSize: 12)),
                trailing: const Text(
                  'F1',
                  style: TextStyle(fontSize: 10, color: Palette.muted),
                ),
                onTap: () => showShortcutHelp(context),
              ),
              const SizedBox(height: 12),
              Tooltip(
                message: repo.syncError ?? 'Данные сохранены на устройстве',
                child: Row(
                  children: [
                    Icon(
                      repo.syncError == null
                          ? Icons.cloud_done_outlined
                          : Icons.cloud_off_outlined,
                      size: 14,
                      color: Palette.muted,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        repo.syncStatus,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Palette.muted,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
  Widget _today(bool desktop) {
    if (!desktop) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: CalendarPane(projectId: projectId),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      child: Dashboard(projectId: projectId),
    );
  }

  Widget _planner(bool desktop) {
    final repo = ref.watch(appProvider);
    final tasks = repo.snapshot.tasks
        .where(
          (t) =>
              repo.snapshot.unscheduled(t, repo.now()) &&
              (projectId.isEmpty || t.projectId == projectId) &&
              t.title.toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    final list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    'Без расписания',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  Text(
                    '${tasks.length}',
                    style: const TextStyle(color: Palette.muted),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                onChanged: (v) => setState(() => query = v),
                decoration: const InputDecoration(
                  hintText: 'Найти задачу',
                  prefixIcon: Icon(Icons.search_rounded, size: 18),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              projectFilter(),
            ],
          ),
        ),
        const Divider(),
        Expanded(
          child: tasks.isEmpty
              ? const EmptyState(
                  icon: Icons.event_available_rounded,
                  title: 'Всё на своих местах',
                  subtitle: 'Создайте задачу или снимите фильтр',
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: tasks.length,
                  itemBuilder: (context, index) => TaskCard(
                    task: tasks[index],
                    selected: selected?.id == tasks[index].id,
                    onSelect: () => setState(() {
                      selected = selected?.id == tasks[index].id
                          ? null
                          : tasks[index];
                      if (!desktop && selected != null) mobileTasks = false;
                    }),
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextButton.icon(
            onPressed: () => openTask(context),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Новая задача'),
          ),
        ),
      ],
    );
    final calendar = Column(
      children: [
        if (selected != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: Palette.blue.withValues(alpha: .09),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.touch_app_outlined,
                  size: 18,
                  color: Palette.blue,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    'Выберите время: ${selected!.title}',
                    style: const TextStyle(fontSize: 12, color: Palette.blue),
                  ),
                ),
                IconButton(
                  tooltip: 'Отменить выбор',
                  onPressed: () => setState(() => selected = null),
                  icon: const Icon(Icons.close_rounded, size: 16),
                ),
              ],
            ),
          ),
        Expanded(
          child: CalendarPane(
            projectId: projectId,
            initialDate: calendarDate,
            selectedTask: selected,
            onPlaced: () => setState(() => selected = null),
          ),
        ),
      ],
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(desktop ? 28 : 12, 0, desktop ? 28 : 12, 16),
      child: desktop
          ? Row(
              children: [
                SizedBox(width: 290, child: Card(child: list)),
                const SizedBox(width: 20),
                Expanded(child: calendar),
              ],
            )
          : Column(
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: true,
                      label: Text('Задачи'),
                      icon: Icon(Icons.list_rounded),
                    ),
                    ButtonSegment(
                      value: false,
                      label: Text('Календарь'),
                      icon: Icon(Icons.calendar_today_outlined),
                    ),
                  ],
                  selected: {mobileTasks},
                  onSelectionChanged: (s) =>
                      setState(() => mobileTasks = s.first),
                ),
                const SizedBox(height: 14),
                Expanded(child: mobileTasks ? list : calendar),
              ],
            ),
    );
  }

  Widget _board() {
    final repo = ref.watch(appProvider);
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final status in TaskStatus.values)
              SizedBox(
                width: math.max(270, (c.maxWidth - 84) / 4),
                child: Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: DragTarget<Task>(
                    key: ValueKey('board-${status.wire}'),
                    onWillAcceptWithDetails: (d) =>
                        d.data.seriesId.isEmpty && d.data.status != status,
                    onAcceptWithDetails: (d) => guard(context, () async {
                      final task = repo.snapshot.task(d.data.id);
                      if (task != null) await repo.status(task, status);
                    }),
                    builder: (context, candidates, rejected) {
                      final tasks = repo.snapshot.tasks
                          .where(
                            (t) =>
                                t.seriesId.isEmpty &&
                                t.status == status &&
                                (projectId.isEmpty || t.projectId == projectId),
                          )
                          .toList();
                      return Container(
                        decoration: BoxDecoration(
                          color: candidates.isNotEmpty
                              ? Palette.blue.withValues(alpha: .08)
                              : Palette.surface.withValues(alpha: .5),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: candidates.isNotEmpty
                                ? Palette.blue
                                : Palette.border,
                            width: .6,
                          ),
                        ),
                        child: Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(17),
                              child: Row(
                                children: [
                                  Container(
                                    width: 7,
                                    height: 7,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: status == TaskStatus.done
                                          ? Palette.green
                                          : status == TaskStatus.inProgress
                                          ? Palette.pink
                                          : status == TaskStatus.waiting
                                          ? Palette.projects[2]
                                          : Palette.blue,
                                    ),
                                  ),
                                  const SizedBox(width: 9),
                                  Text(
                                    status.label,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    '${tasks.length}',
                                    style: const TextStyle(
                                      color: Palette.muted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: ListView.builder(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                itemCount: tasks.length,
                                itemBuilder: (context, i) =>
                                    BoardTask(task: tasks[i]),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class SearchDialog extends ConsumerStatefulWidget {
  const SearchDialog({super.key});
  @override
  ConsumerState<SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends ConsumerState<SearchDialog> {
  List<Entity> results = [];
  bool busy = false;
  String? error;
  Timer? debounce;
  int generation = 0;
  void find(String value) {
    debounce?.cancel();
    final current = ++generation;
    setState(() => busy = true);
    debounce = Timer(const Duration(milliseconds: 140), () async {
      try {
        final next = await ref.read(appProvider).db.search(value);
        if (mounted && current == generation) {
          setState(() {
            results = next;
            busy = false;
            error = null;
          });
        }
      } catch (e) {
        if (mounted && current == generation) {
          setState(() {
            error = '$e';
            busy = false;
          });
        }
      }
    });
  }

  @override
  void dispose() {
    debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 660,
      height: 540,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(18),
            child: TextField(
              autofocus: true,
              onChanged: find,
              decoration: const InputDecoration(
                hintText: 'Поиск по задачам, описаниям и заметкам',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
          ),
          if (busy) const LinearProgressIndicator(minHeight: 1),
          const Divider(),
          Expanded(
            child: error != null
                ? Center(child: Text(error!))
                : results.isEmpty
                ? const EmptyState(
                    icon: Icons.search_rounded,
                    title: 'Найдётся даже прошлое',
                    subtitle:
                        'Введите слово или начало слова.\nПоиск работает без интернета.',
                  )
                : ListView.builder(
                    itemCount: results.length,
                    itemBuilder: (context, i) {
                      final e = results[i];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 6,
                        ),
                        leading: Icon(
                          e.kind == 'note'
                              ? Icons.description_outlined
                              : Icons.event_outlined,
                          color: Palette.blue,
                        ),
                        title: Text(
                          e.data['title'] as String? ?? '',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          e.data['content'] as String? ??
                              e.data['description'] as String? ??
                              '',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => Navigator.pop(context, e),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}
