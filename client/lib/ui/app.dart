import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;
import '../data/repository.dart';
import '../domain/models.dart';
import '../domain/recurrence.dart';
import 'calendar.dart';
import 'birthdays.dart';
import 'dashboard.dart';
import 'shortcuts.dart';
import 'timer_control.dart';
import 'notes.dart';
import 'providers.dart';
import 'settings.dart';
import 'task_card.dart';
import 'task_editor.dart';
import 'theme.dart';
import 'app_logo.dart';
import 'ai_settings.dart';
import 'server_settings.dart';

class YggvionApp extends ConsumerWidget {
  const YggvionApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
    title: 'Yggvion',
    debugShowCheckedModeBanner: false,
    theme: appTheme(
      accentColor: ref.watch(
        appProvider.select((repo) => repo.snapshot.settings.accentColor),
      ),
    ),
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
  String? newNoteId;
  Future<void>? noteCleanup;
  DateTime? calendarDate, homeDate;
  Timer? ticker;
  StreamSubscription<Uri>? invitationLinks;
  bool mobileTasks = true;
  bool birthdaysOpen = false;
  double? sidebarWidth, sidebarDragOrigin, sidebarDragWidth;
  bool sidebarEdgeHovered = false;
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
  static const mobilePages = [
    PageKind.board,
    PageKind.planner,
    PageKind.notes,
    PageKind.today,
  ];
  @override
  void initState() {
    super.initState();
    final repo = ref.read(appProvider);
    homeDate = tz.TZDateTime.from(
      repo.now(),
      tz.getLocation(repo.snapshot.settings.timezone),
    );
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
      invitationLinks = ref
          .read(invitationLinksProvider)
          ?.listen(
            (uri) {
              if (mounted && uri.scheme == 'yggvion' && uri.host == 'connect') {
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        SynchronizationPage(invitation: uri.toString()),
                  ),
                );
              }
            },
            onError: (Object error) {
              if (mounted && error is! MissingPluginException) {
                setState(
                  () => runtimeError =
                      'Не удалось открыть приглашение. Вставьте ссылку в разделе «Синхронизация».',
                );
              }
            },
          );
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
    invitationLinks?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void go(PageKind next) {
    if (page == PageKind.notes && next != PageKind.notes) {
      final repo = ref.read(appProvider);
      final noteIds = repo.snapshot.notes
          .where((note) => note.pinned.isEmpty)
          .map((note) => note.id)
          .toList();
      if (noteIds.isNotEmpty) {
        final cleanup = guard(context, () => repo.discardEmptyNotes(noteIds));
        noteCleanup = cleanup;
        unawaited(
          cleanup.whenComplete(() {
            if (mounted && noteCleanup == cleanup) {
              setState(() => noteCleanup = null);
            }
          }),
        );
      }
    }
    setState(() {
      page = next;
      selected = null;
      newNoteId = null;
      birthdaysOpen = false;
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
        newNoteId = null;
      });
    } else if (result.kind == 'task') {
      await openTask(context, task: Task(result));
    } else if (result.kind == 'series') {
      go(PageKind.planner);
      setState(() {
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
      newNoteId = note.id;
    });
  });

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(appProvider), size = MediaQuery.sizeOf(context);
    ref.listen(appProvider, (_, current) {
      if (projectId.isNotEmpty &&
          !current.snapshot.projects.any(
            (project) => project.id == projectId,
          )) {
        setState(() => projectId = '');
      }
    });
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
          if (birthdaysOpen) {
            setState(() => birthdaysOpen = false);
          } else if (selected != null) {
            setState(() => selected = null);
          }
        },
      },
      // Unfocusing an input must land inside the workspace shortcut handler,
      // not on the Navigator's route scope above it.
      child: FocusScope(
        autofocus: true,
        debugLabel: 'Workspace',
        child: Scaffold(
          body: SafeArea(
            child: Row(
              children: [
                if (desktop) _sidebar(repo, conflicts),
                Expanded(
                  child: Column(
                    children: [
                      _header(repo, desktop),
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
                          // Do not reopen a stale empty draft while its queued
                          // deletion is still being written.
                          PageKind.notes =>
                            noteCleanup != null
                                ? const Center(
                                    child: CircularProgressIndicator(
                                      key: ValueKey('note-cleanup-progress'),
                                    ),
                                  )
                                : NotesPage(
                                    key: ValueKey(selectedNote),
                                    initialId: selectedNote,
                                    editId: newNoteId,
                                  ),
                          PageKind.settings => PopScope(
                            canPop: !birthdaysOpen,
                            onPopInvokedWithResult: (didPop, _) {
                              if (!didPop) {
                                setState(() => birthdaysOpen = false);
                              }
                            },
                            child: IndexedStack(
                              index: birthdaysOpen ? 1 : 0,
                              children: [
                                SettingsPage(
                                  onOpenBirthdays: () =>
                                      setState(() => birthdaysOpen = true),
                                ),
                                if (birthdaysOpen) const BirthdayPage(),
                              ],
                            ),
                          ),
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
                  selectedIndex: mobilePages.indexOf(
                    page == PageKind.settings ? PageKind.today : page,
                  ),
                  onDestinationSelected: (i) => go(mobilePages[i]),
                  destinations: [
                    for (final destination in mobilePages)
                      NavigationDestination(
                        key: ValueKey('mobile-nav-${destination.name}'),
                        icon: Icon(icons[destination.index]),
                        label: labels[destination.index],
                      ),
                  ],
                ),
          floatingActionButton: desktop || page == PageKind.settings
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const AssistantButton(),
                    if (ref.watch(
                      aiProvider.select((ai) => ai?.enabled ?? false),
                    ))
                      const SizedBox(width: 12),
                    PopupMenuButton<String>(
                      tooltip: 'Создать',
                      onSelected: (v) => guard(context, () async {
                        if (v == 'task') {
                          await openTask(context);
                        } else {
                          await createNote();
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
                          color: context.accentColor,
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
                  ],
                ),
        ),
      ),
    );
  }

  Widget _header(Repository repo, bool desktop) => LayoutBuilder(
    builder: (context, constraints) {
      final home = page == PageKind.today;
      final birthdays = page == PageKind.settings && birthdaysOpen;
      final zone = tz.getLocation(repo.snapshot.settings.timezone);
      final now = tz.TZDateTime.from(repo.now(), zone);
      final date = tz.TZDateTime.from(homeDate ?? now, zone);
      final wide = desktop && constraints.maxWidth >= 1100;
      final toolbar = CalendarToolbar(
        date: date,
        view: repo.calendarView,
        now: now,
        timezone: repo.snapshot.settings.timezone,
        showDate: desktop,
        onDateChanged: (value) => setState(() => homeDate = value),
        onViewChanged: (value) => guard(context, () => repo.setView(value)),
      );
      final title = home
          ? Text(
              CalendarToolbar.dateLabel(date, repo.calendarView),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w600,
                letterSpacing: -.5,
              ),
            )
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  birthdays ? 'Дни рождения' : labels[page.index],
                  style: TextStyle(
                    fontSize: desktop ? 26 : 22,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -.8,
                  ),
                ),
                if (desktop)
                  Text(
                    birthdays
                        ? 'Настройки · Близкие люди и важные даты'
                        : page == PageKind.planner
                        ? 'Найдите время для важного'
                        : page == PageKind.board
                        ? 'От идеи до завершения'
                        : page == PageKind.notes
                        ? 'Место для мыслей и знаний'
                        : 'Ваше рабочее пространство',
                    style: const TextStyle(color: Palette.muted, fontSize: 12),
                  ),
              ],
            );
      final actions = birthdays
          ? <Widget>[
              if (desktop)
                FilledButton.icon(
                  key: const ValueKey('add-birthday'),
                  onPressed: () => editBirthday(context),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Добавить день рождения'),
                )
              else
                IconButton.filledTonal(
                  key: const ValueKey('add-birthday'),
                  tooltip: 'Добавить день рождения',
                  onPressed: () => editBirthday(context),
                  icon: const Icon(Icons.add_rounded, size: 22),
                ),
            ]
          : <Widget>[
              if (!desktop &&
                  page != PageKind.settings &&
                  page != PageKind.notes &&
                  repo.snapshot.projects.isNotEmpty)
                PopupMenuButton<String>(
                  tooltip: 'Фильтр проектов',
                  icon: Icon(
                    Icons.filter_list_rounded,
                    color: projectId.isEmpty
                        ? Palette.muted
                        : context.accentColor,
                  ),
                  onSelected: (value) => setState(() => projectId = value),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: '', child: Text('Все проекты')),
                    for (final project in repo.snapshot.projects)
                      PopupMenuItem(
                        value: project.id,
                        child: Text(project.title),
                      ),
                  ],
                ),
              TimerControl(compact: !wide),
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
              if (desktop && page != PageKind.settings) ...[
                const SizedBox(width: 8),
                if (wide)
                  OutlinedButton.icon(
                    onPressed: createNote,
                    icon: const Icon(Icons.note_add_outlined, size: 17),
                    label: const Text('Заметка'),
                  )
                else
                  IconButton(
                    tooltip: 'Создать заметку',
                    onPressed: createNote,
                    icon: const Icon(Icons.note_add_outlined, size: 20),
                  ),
                const SizedBox(width: 8),
                if (wide)
                  FilledButton.icon(
                    onPressed: () => openTask(context),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Задача'),
                  )
                else
                  IconButton.filled(
                    tooltip: 'Создать задачу',
                    onPressed: () => openTask(context),
                    icon: const Icon(Icons.add_rounded, size: 20),
                  ),
                const AssistantButton(),
              ],
            ];
      return Container(
        key: const ValueKey('workspace-header'),
        height: home && !desktop
            ? 108
            : desktop
            ? 78
            : 68,
        padding: EdgeInsets.symmetric(horizontal: desktop ? 24 : 12),
        child: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  if (birthdays || (!desktop && page == PageKind.settings))
                    IconButton(
                      key: birthdays
                          ? const ValueKey('back-from-birthdays')
                          : null,
                      tooltip: birthdays ? 'К настройкам' : 'К календарю',
                      onPressed: birthdays
                          ? () => setState(() => birthdaysOpen = false)
                          : () => go(PageKind.today),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                  Expanded(child: home && desktop ? toolbar : title),
                  const SizedBox(width: 12),
                  ...actions,
                ],
              ),
            ),
            if (home && !desktop)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: toolbar,
              ),
          ],
        ),
      );
    },
  );

  void cancelSidebarResize() {
    setState(() {
      sidebarWidth = null;
      sidebarDragOrigin = null;
      sidebarDragWidth = null;
    });
  }

  Widget _sidebar(Repository repo, int conflicts) {
    const expandedWidth = 215.0, collapsedWidth = 72.0;
    final width =
        sidebarWidth ??
        (repo.sidebarCollapsed ? collapsedWidth : expandedWidth);
    final collapsed = width < expandedWidth / 2;
    void finish() {
      if (sidebarDragOrigin == null) return;
      final nextCollapsed = (sidebarWidth ?? width) < expandedWidth / 2;
      guard(context, () => repo.setSidebarCollapsed(nextCollapsed));
      setState(() {
        sidebarWidth = null;
        sidebarDragOrigin = null;
        sidebarDragWidth = null;
      });
    }

    final logo = Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: context.accentColor.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const AppLogo(),
    );
    Widget navigation(int index) {
      final icon = Icon(icons[index], size: 20);
      final selected = page.index == index;
      return Padding(
        padding: EdgeInsets.fromLTRB(
          collapsed ? 14 : 12,
          2,
          collapsed ? 14 : 12,
          2,
        ),
        child: collapsed
            ? IconButton(
                key: ValueKey('nav-${PageKind.values[index].name}'),
                tooltip: labels[index],
                style: IconButton.styleFrom(
                  foregroundColor: selected
                      ? context.accentColor
                      : Palette.muted,
                  backgroundColor: selected
                      ? context.accentColor.withValues(alpha: .09)
                      : Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () => go(PageKind.values[index]),
                icon: index == PageKind.settings.index && conflicts > 0
                    ? Badge(label: Text('$conflicts'), child: icon)
                    : icon,
              )
            : ListTile(
                key: ValueKey('nav-${PageKind.values[index].name}'),
                dense: true,
                selected: selected,
                selectedColor: context.accentColor,
                selectedTileColor: context.accentColor.withValues(alpha: .09),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                leading: icon,
                title: Text(
                  labels[index],
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                trailing: index == PageKind.settings.index && conflicts > 0
                    ? Badge(label: Text('$conflicts'))
                    : null,
                onTap: () => go(PageKind.values[index]),
              ),
      );
    }

    return AnimatedContainer(
      duration: sidebarWidth == null
          ? const Duration(milliseconds: 180)
          : Duration.zero,
      curve: Curves.easeOutCubic,
      key: const ValueKey('workspace-sidebar'),
      width: width,
      decoration: const BoxDecoration(
        color: Palette.surface,
        border: Border(right: BorderSide(color: Palette.border, width: .6)),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRect(
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: collapsed ? collapsedWidth : expandedWidth,
              maxWidth: collapsed ? collapsedWidth : expandedWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (collapsed) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 26, bottom: 30),
                      child: Center(child: logo),
                    ),
                  ] else
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 22, 8, 26),
                      child: Row(
                        children: [
                          logo,
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Yggvion',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -.9,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  for (var i = 0; i < 4; i++) navigation(i),
                  const SizedBox(height: 30),
                  if (!collapsed) ...[
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
                  ],
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      children: [
                        for (final p in repo.snapshot.projects)
                          if (collapsed)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Semantics(
                                selected: projectId == p.id,
                                child: IconButton(
                                  key: ValueKey('sidebar-project-${p.id}'),
                                  tooltip: p.title,
                                  style: IconButton.styleFrom(
                                    minimumSize: const Size(44, 44),
                                    backgroundColor: projectId == p.id
                                        ? Color(p.color).withValues(alpha: .14)
                                        : Colors.transparent,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      side: BorderSide(
                                        color: projectId == p.id
                                            ? Color(
                                                p.color,
                                              ).withValues(alpha: .45)
                                            : Colors.transparent,
                                      ),
                                    ),
                                  ),
                                  onPressed: () => setState(
                                    () => projectId = projectId == p.id
                                        ? ''
                                        : p.id,
                                  ),
                                  icon: Icon(
                                    Icons.circle,
                                    size: 12,
                                    color: Color(p.color),
                                  ),
                                ),
                              ),
                            )
                          else
                            ListTile(
                              key: ValueKey('sidebar-project-${p.id}'),
                              dense: true,
                              leading: Icon(
                                Icons.circle,
                                size: 8,
                                color: Color(p.color),
                              ),
                              title: Text(
                                p.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                              selected: projectId == p.id,
                              onTap: () => setState(
                                () => projectId = projectId == p.id ? '' : p.id,
                              ),
                            ),
                        if (repo.snapshot.projects.isEmpty && !collapsed)
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
                  navigation(PageKind.settings.index),
                  if (collapsed) ...[
                    IconButton(
                      tooltip: 'Клавиши · F1',
                      onPressed: () => showShortcutHelp(context),
                      icon: const Icon(Icons.keyboard_outlined, size: 20),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Tooltip(
                        message: repo.syncError ?? repo.syncStatus,
                        child: Icon(
                          repo.syncError == null
                              ? Icons.cloud_done_outlined
                              : Icons.cloud_off_outlined,
                          size: 16,
                          color: Palette.muted,
                        ),
                      ),
                    ),
                  ] else
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        children: [
                          ListTile(
                            dense: true,
                            leading: const Icon(
                              Icons.keyboard_outlined,
                              size: 19,
                            ),
                            horizontalTitleGap: 10,
                            minLeadingWidth: 20,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                            ),
                            title: const Text(
                              'Клавиши',
                              style: TextStyle(fontSize: 12),
                            ),
                            trailing: const Text(
                              'F1',
                              style: TextStyle(
                                fontSize: 10,
                                color: Palette.muted,
                              ),
                            ),
                            onTap: () => showShortcutHelp(context),
                          ),
                          const SizedBox(height: 12),
                          Tooltip(
                            message:
                                repo.syncError ??
                                'Данные сохранены на устройстве',
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
            ),
          ),
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: 10,
            child: Semantics(
              label: 'Ширина бокового меню',
              value: collapsed ? 'Свёрнуто' : 'Развёрнуто',
              increasedValue: 'Развёрнуто',
              decreasedValue: 'Свёрнуто',
              onIncrease: () =>
                  guard(context, () => repo.setSidebarCollapsed(false)),
              onDecrease: () =>
                  guard(context, () => repo.setSidebarCollapsed(true)),
              child: Tooltip(
                message: 'Потяните границу, чтобы свернуть или развернуть меню',
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeLeftRight,
                  onEnter: (_) => setState(() => sidebarEdgeHovered = true),
                  onExit: (_) => setState(() => sidebarEdgeHovered = false),
                  child: Listener(
                    onPointerCancel: (_) => cancelSidebarResize(),
                    child: GestureDetector(
                      key: const ValueKey('sidebar-resize-handle'),
                      dragStartBehavior: DragStartBehavior.down,
                      behavior: HitTestBehavior.opaque,
                      supportedDevices: const {
                        PointerDeviceKind.mouse,
                        PointerDeviceKind.touch,
                        PointerDeviceKind.stylus,
                      },
                      onHorizontalDragStart: (details) => setState(() {
                        sidebarDragOrigin = details.globalPosition.dx;
                        sidebarDragWidth = width;
                        sidebarWidth = width;
                      }),
                      onHorizontalDragUpdate: (details) => setState(() {
                        sidebarWidth =
                            (sidebarDragWidth! +
                                    details.globalPosition.dx -
                                    sidebarDragOrigin!)
                                .clamp(collapsedWidth, expandedWidth);
                      }),
                      onHorizontalDragEnd: (_) => finish(),
                      onHorizontalDragCancel: cancelSidebarResize,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          width: 2,
                          color: sidebarEdgeHovered || sidebarWidth != null
                              ? context.accentColor.withValues(alpha: .65)
                              : Colors.transparent,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _today(bool desktop) {
    if (!desktop) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: CalendarPane(
          projectId: projectId,
          initialDate: homeDate,
          showToolbar: false,
          onDateChanged: (value) => setState(() => homeDate = value),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      child: Dashboard(projectId: projectId, date: homeDate),
    );
  }

  Widget _planner(bool desktop) {
    final repo = ref.watch(appProvider);
    final tasks = repo.snapshot.tasks
        .where(
          (t) =>
              t.seriesId.isEmpty &&
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
              color: context.accentColor.withValues(alpha: .09),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.touch_app_outlined,
                  size: 18,
                  color: context.accentColor,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    'Выберите время: ${selected!.title}',
                    style: TextStyle(fontSize: 12, color: context.accentColor),
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
            onDateChanged: (value) => setState(() => calendarDate = value),
            selectedTask: selected,
            planner: true,
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
                              ? context.accentColor.withValues(alpha: .08)
                              : Palette.surface.withValues(alpha: .5),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: candidates.isNotEmpty
                                ? context.accentColor
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
                                          : context.accentColor,
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
                          color: context.accentColor,
                        ),
                        title: Text(
                          e.kind == 'note'
                              ? Note(e).displayLabel
                              : e.data['title'] as String? ?? '',
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
