import '../l10n/strings.dart';
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
import '../domain/fuzzy_search.dart';
import '../domain/recurrence.dart';
import 'calendar.dart';
import 'birthdays.dart';
import 'dashboard.dart';
import 'shortcuts.dart';
import 'timer_control.dart';
import 'calendar_sharing.dart';
import 'notes.dart';
import 'attachments.dart';
import 'providers.dart';
import 'settings.dart';
import 'task_card.dart';
import 'task_editor.dart';
import 'theme.dart';
import 'app_logo.dart';
import 'interface_scale.dart';
import 'server_settings.dart';

class YggvionApp extends ConsumerWidget {
  const YggvionApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
    title: 'Yggvion',
    debugShowCheckedModeBanner: false,
    theme: appTheme(
      brightness: ref.watch(appProvider.select((repo) => repo.lightTheme))
          ? Brightness.light
          : Brightness.dark,
      accentColor: ref.watch(
        appProvider.select((repo) => repo.snapshot.settings.accentColor),
      ),
    ),
    locale: Locale(ref.watch(appProvider.select((repo) => repo.language))),
    supportedLocales: const [
      Locale('ru'),
      Locale('en'),
      Locale('es'),
      Locale('de'),
      Locale('zh'),
      Locale('hi'),
    ],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
      value:
          (Theme.of(context).brightness == Brightness.light
                  ? SystemUiOverlayStyle.dark
                  : SystemUiOverlayStyle.light)
              .copyWith(
                statusBarColor: Colors.transparent,
                systemNavigationBarColor: context.palette.background,
              ),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => ref.read(activityProvider)?.interact(),
        onPointerMove: (_) => ref.read(activityProvider)?.interact(),
        onPointerHover: (_) => ref.read(activityProvider)?.interact(),
        onPointerSignal: (_) => ref.read(activityProvider)?.interact(),
        onPointerPanZoomStart: (_) => ref.read(activityProvider)?.interact(),
        onPointerPanZoomUpdate: (_) => ref.read(activityProvider)?.interact(),
        child: InterfaceScale(
          scale: ref.watch(appProvider.select((repo) => repo.interfaceScale)),
          child: child!,
        ),
      ),
    ),
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
  int boardDoneDays = 7, boardDoneLimit = 50;
  late double plannerFraction;
  bool birthdaysOpen = false;
  double? sidebarWidth, sidebarDragOrigin, sidebarDragWidth;
  bool sidebarEdgeHovered = false;
  String? runtimeError;
  static List<String> get labels => [
    tr("Сегодня"),
    tr("Планировщик"),
    tr("Канбан"),
    tr("Заметки"),
    tr("Настройки"),
  ];
  static const icons = [
    Icons.wb_sunny_outlined,
    Icons.calendar_month_outlined,
    Icons.view_kanban_outlined,
    Icons.description_outlined,
    Icons.tune_rounded,
  ];
  List<PageKind> get mobilePages => [
    PageKind.board,
    PageKind.planner,
    PageKind.notes,
    PageKind.today,
  ];
  @override
  void initState() {
    super.initState();
    final repo = ref.read(appProvider);
    plannerFraction = repo.plannerFraction;
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
                  () => runtimeError = tr(
                    "Не удалось открыть приглашение. Вставьте ссылку в разделе «Синхронизация».",
                  ),
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
      unawaited(ref.read(localBackupProvider).runIfDue());
      await repo.rollover();
      await RecurrenceService(repo).expand(
        repo.now().subtract(const Duration(days: 1)),
        repo.now().add(const Duration(days: 90)),
      );
      if (mounted) setState(() => runtimeError = null);
    } catch (e) {
      if (mounted) {
        setState(
          () => runtimeError = tr("Не удалось обновить календарь: {0}", [e]),
        );
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
      if (next == PageKind.board && page != next) {
        boardDoneDays = 7;
        boardDoneLimit = 50;
      }
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
    final repo = ref.read(appProvider);
    final folder = page == PageKind.notes
        ? ref.read(selectedNoteFolderProvider)
        : '';
    final note = await repo.createNote(
      folderId: repo.snapshot.noteFolders.any((f) => f.id == folder)
          ? folder
          : '',
    );
    if (!mounted) return;
    setState(() {
      page = PageKind.notes;
      selectedNote = note.id;
      newNoteId = note.id;
    });
  });

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(appProvider);
    ref.listen(openNoteProvider, (_, id) {
      if (id == null) return;
      FocusManager.instance.primaryFocus?.unfocus();
      Navigator.of(context).popUntil((route) => route.isFirst);
      setState(() {
        page = PageKind.notes;
        selectedNote = id;
        selected = null;
        newNoteId = null;
        birthdaysOpen = false;
      });
      ref.read(openNoteProvider.notifier).state = null;
    });
    ref.listen(appProvider, (_, current) {
      if (projectId.isNotEmpty &&
          !current.snapshot.projects.any(
            (project) => project.id == projectId,
          )) {
        setState(() => projectId = '');
      }
    });
    final desktop = !usesMobileLayout(context);
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
                              child: Text(tr("Повторить")),
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
                            color: context.palette.pink.withValues(alpha: .1),
                            child: Text(
                              tr(
                                "Есть изменения с разных устройств ({0}) · Выбрать или объединить",
                                [conflicts],
                              ),
                              style: TextStyle(
                                color: context.palette.pink,
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
                                    keyboardVisible:
                                        MediaQuery.viewInsetsOf(
                                          context,
                                        ).bottom >
                                        0,
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
                  labelBehavior: MediaQuery.sizeOf(context).width < 330
                      ? NavigationDestinationLabelBehavior.alwaysHide
                      : NavigationDestinationLabelBehavior.alwaysShow,
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
          floatingActionButton:
              desktop ||
                  page == PageKind.settings ||
                  (page == PageKind.notes &&
                      MediaQuery.viewInsetsOf(context).bottom > 0)
              ? null
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _MobileCreateButton(
                      key: const ValueKey('create-event'),
                      label: tr("Событие"),
                      icon: Icons.event_outlined,
                      primary: true,
                      onPressed: () => guard(context, () => openTask(context)),
                    ),
                    const SizedBox(height: 12),
                    _MobileCreateButton(
                      key: const ValueKey('create-note'),
                      label: tr("Заметка"),
                      icon: Icons.note_add_outlined,
                      onPressed: () => guard(context, createNote),
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
                  birthdays ? tr("Дни рождения") : labels[page.index],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: desktop ? 26 : 22,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -.8,
                  ),
                ),
                if (desktop && page == PageKind.settings)
                  Text(
                    birthdays
                        ? tr("Настройки · Близкие люди и важные даты")
                        : tr("Ваше рабочее пространство"),
                    style: TextStyle(
                      color: context.palette.muted,
                      fontSize: 12,
                    ),
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
                  label: Text(tr("Добавить день рождения")),
                )
              else
                IconButton.filledTonal(
                  key: const ValueKey('add-birthday'),
                  tooltip: tr("Добавить день рождения"),
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
                  tooltip: tr("Фильтр проектов"),
                  icon: Icon(
                    Icons.filter_list_rounded,
                    color: projectId.isEmpty
                        ? context.palette.muted
                        : context.accentColor,
                  ),
                  onSelected: (value) => setState(() => projectId = value),
                  itemBuilder: (_) => [
                    PopupMenuItem(value: '', child: Text(tr("Все проекты"))),
                    for (final project in repo.snapshot.projects)
                      PopupMenuItem(
                        value: project.id,
                        child: Text(project.title),
                      ),
                  ],
                ),
              if ((home || page == PageKind.planner) &&
                  ref.read(syncProvider).connected)
                IconButton(
                  key: const ValueKey('share-calendar'),
                  tooltip: tr("Поделиться календарём"),
                  onPressed: () => shareCalendar(context),
                  icon: const Icon(Icons.ios_share_rounded, size: 20),
                ),
              if (!desktop && page == PageKind.notes)
                IconButton(
                  key: const ValueKey('mobile-notes-attachments'),
                  tooltip: tr("Вложения"),
                  onPressed: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    openAttachments(context);
                  },
                  icon: const Icon(Icons.attach_file_rounded, size: 21),
                ),
              TimerControl(compact: !wide),
              IconButton(
                tooltip: tr("Поиск · ⌘F / Ctrl+F"),
                onPressed: search,
                icon: const Icon(Icons.search_rounded),
              ),
              if (!desktop)
                IconButton(
                  tooltip: tr("Настройки"),
                  onPressed: () => go(PageKind.settings),
                  icon: const Icon(Icons.tune_rounded),
                ),
              if (desktop && page != PageKind.settings) ...[
                const SizedBox(width: 8),
                if (wide)
                  OutlinedButton.icon(
                    onPressed: createNote,
                    icon: const Icon(Icons.note_add_outlined, size: 17),
                    label: Text(tr("Заметка")),
                  )
                else
                  IconButton(
                    tooltip: tr("Создать заметку"),
                    onPressed: createNote,
                    icon: const Icon(Icons.note_add_outlined, size: 20),
                  ),
                const SizedBox(width: 8),
                if (wide)
                  FilledButton.icon(
                    onPressed: () => openTask(context),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: Text(tr("Задача")),
                  )
                else
                  IconButton.filled(
                    tooltip: tr("Создать задачу"),
                    onPressed: () => openTask(context),
                    icon: const Icon(Icons.add_rounded, size: 20),
                  ),
              ],
            ];
      final narrow = !desktop && constraints.maxWidth < 330;
      final heading = Row(
        children: [
          if (birthdays || (!desktop && page == PageKind.settings))
            IconButton(
              key: birthdays ? const ValueKey('back-from-birthdays') : null,
              tooltip: birthdays ? tr("К настройкам") : tr("К календарю"),
              onPressed: birthdays
                  ? () => setState(() => birthdaysOpen = false)
                  : () => go(PageKind.today),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
          Expanded(
            child: home && desktop
                ? toolbar
                : !desktop && page == PageKind.planner
                ? plannerSwitcher(compact: constraints.maxWidth < 420)
                : title,
          ),
          if (!narrow) ...[const SizedBox(width: 8), ...actions],
        ],
      );
      return Container(
        key: const ValueKey('workspace-header'),
        height: narrow
            ? (home ? 136 : 88)
            : home && !desktop
            ? 108
            : desktop
            ? 78
            : 68,
        padding: EdgeInsets.symmetric(horizontal: desktop ? 24 : 12),
        child: Column(
          children: [
            Expanded(child: heading),
            if (narrow)
              SizedBox(
                height: 40,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Row(mainAxisSize: MainAxisSize.min, children: actions),
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
                      : context.palette.muted,
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
      decoration: BoxDecoration(
        color: context.palette.surface,
        border: Border(
          right: BorderSide(color: context.palette.border, width: .6),
        ),
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
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 26),
                      child: Text(
                        tr("ПРОЕКТЫ"),
                        style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 1.7,
                          color: context.palette.muted,
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
                            label: Text(
                              tr("Добавить проект"),
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                    ),
                  ),
                  navigation(PageKind.settings.index),
                  if (collapsed) ...[
                    IconButton(
                      tooltip: tr("Клавиши · F1"),
                      onPressed: () => showShortcutHelp(context),
                      icon: const Icon(Icons.keyboard_outlined, size: 20),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Tooltip(
                        message: repo.syncError ?? tr(repo.syncStatus),
                        child: Icon(
                          repo.syncError == null
                              ? Icons.cloud_done_outlined
                              : Icons.cloud_off_outlined,
                          size: 16,
                          color: context.palette.muted,
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
                            title: Text(
                              tr("Клавиши"),
                              style: TextStyle(fontSize: 12),
                            ),
                            trailing: Text(
                              'F1',
                              style: TextStyle(
                                fontSize: 10,
                                color: context.palette.muted,
                              ),
                            ),
                            onTap: () => showShortcutHelp(context),
                          ),
                          const SizedBox(height: 12),
                          Tooltip(
                            message:
                                repo.syncError ??
                                tr("Данные сохранены на устройстве"),
                            child: Row(
                              children: [
                                Icon(
                                  repo.syncError == null
                                      ? Icons.cloud_done_outlined
                                      : Icons.cloud_off_outlined,
                                  size: 14,
                                  color: context.palette.muted,
                                ),
                                const SizedBox(width: 7),
                                Expanded(
                                  child: Text(
                                    tr(repo.syncStatus),
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: context.palette.muted,
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
              label: tr("Ширина бокового меню"),
              value: collapsed ? tr("Свёрнуто") : tr("Развёрнуто"),
              increasedValue: tr("Развёрнуто"),
              decreasedValue: tr("Свёрнуто"),
              onIncrease: () =>
                  guard(context, () => repo.setSidebarCollapsed(false)),
              onDecrease: () =>
                  guard(context, () => repo.setSidebarCollapsed(true)),
              child: Tooltip(
                message: tr(
                  "Потяните границу, чтобы свернуть или развернуть меню",
                ),
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
      child: Dashboard(
        projectId: projectId,
        date: homeDate,
        onDateChanged: (value) => setState(() => homeDate = value),
      ),
    );
  }

  Widget plannerSwitcher({required bool compact}) {
    if (compact) {
      return PopupMenuButton<bool>(
        key: const ValueKey('planner-mode'),
        tooltip: tr("Раздел планировщика"),
        initialValue: mobileTasks,
        onSelected: (value) => setState(() => mobileTasks = value),
        itemBuilder: (_) => [
          PopupMenuItem(value: true, child: Text(tr("Задачи"))),
          PopupMenuItem(value: false, child: Text(tr("Календарь"))),
        ],
        child: Row(
          children: [
            Flexible(
              child: Text(
                mobileTasks ? tr("Задачи") : tr("Календарь"),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Icon(Icons.expand_more_rounded, size: 18),
          ],
        ),
      );
    }
    return SegmentedButton<bool>(
      key: const ValueKey('planner-mode'),
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        minimumSize: Size.zero,
        textStyle: Theme.of(
          context,
        ).textTheme.labelLarge?.copyWith(fontSize: 12),
        side: BorderSide(color: context.palette.border, width: .6),
      ),
      segments: [
        ButtonSegment(value: true, label: Text(tr("Задачи"))),
        ButtonSegment(value: false, label: Text(tr("Календарь"))),
      ],
      selected: {mobileTasks},
      onSelectionChanged: (value) => setState(() => mobileTasks = value.single),
    );
  }

  Widget _planner(bool desktop) {
    final repo = ref.watch(appProvider);
    final currentSelection = selected == null
        ? null
        : repo.snapshot.task(selected!.id);
    final matching = repo.snapshot.tasks.reversed
        .where(
          (t) =>
              t.seriesId.isEmpty &&
              repo.snapshot.unscheduled(t, repo.now()) &&
              (projectId.isEmpty || t.projectId == projectId) &&
              t.title.toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    final tasks = [
      ...matching.where((t) => t.isProposed),
      ...matching.where((t) => !t.isProposed),
    ];
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
                  Expanded(
                    child: Text(
                      tr("Без расписания"),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${tasks.length}',
                    style: TextStyle(color: context.palette.muted),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                onChanged: (v) => setState(() => query = v),
                decoration: InputDecoration(
                  hintText: tr("Найти задачу"),
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
              ? EmptyState(
                  icon: Icons.event_available_rounded,
                  title: tr("Всё на своих местах"),
                  subtitle: tr("Создайте задачу или снимите фильтр"),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: tasks.length,
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    void choose() => setState(() {
                      selected = selected?.id == task.id ? null : task;
                      if (!desktop && selected != null) mobileTasks = false;
                    });
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (task.isProposed && index == 0)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(4, 2, 4, 12),
                            child: Text(
                              tr("Предложения · {0}", [
                                tasks.where((t) => t.isProposed).length,
                              ]),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: context.accentColor,
                              ),
                            ),
                          ),
                        if (!task.isProposed &&
                            index > 0 &&
                            tasks[index - 1].isProposed)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(4, 10, 4, 12),
                            child: Text(
                              tr("Ваши задачи"),
                              style: TextStyle(
                                fontSize: 12,
                                color: context.palette.muted,
                              ),
                            ),
                          ),
                        if (task.isProposed)
                          ProposedTaskCard(
                            task: task,
                            selected: selected?.id == task.id,
                            onSelect: choose,
                            onResolved: () {
                              if (selected?.id == task.id) {
                                setState(() => selected = null);
                              }
                            },
                          )
                        else
                          TaskCard(
                            task: task,
                            selected: selected?.id == task.id,
                            showDescription: true,
                            onSelect: choose,
                          ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
    final calendar = Column(
      children: [
        if (currentSelection != null)
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
                    tr("Выберите время: {0}", [currentSelection.title]),
                    style: TextStyle(fontSize: 12, color: context.accentColor),
                  ),
                ),
                IconButton(
                  tooltip: tr("Отменить выбор"),
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
            selectedTask: currentSelection,
            planner: true,
            onPlaced: () => setState(() => selected = null),
          ),
        ),
      ],
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(desktop ? 28 : 12, 0, desktop ? 28 : 12, 16),
      child: desktop
          ? LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth - 16;
                final minimum = (240 / width).clamp(.2, .6);
                final maximum = (1 - 380 / width).clamp(minimum, .6);
                final fraction = plannerFraction.clamp(minimum, maximum);
                void save() => guard(
                  context,
                  () => repo.savePlannerLayout(plannerFraction),
                );
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      key: const ValueKey('planner-task-panel'),
                      width: width * fraction,
                      child: Card(child: list),
                    ),
                    PanelDivider(
                      key: const ValueKey('planner-calendar-divider'),
                      axis: Axis.vertical,
                      label: tr("Размер списка задач и календаря"),
                      onDelta: (delta) => setState(
                        () => plannerFraction = (fraction + delta / width)
                            .clamp(minimum, maximum),
                      ),
                      onEnd: save,
                      onReset: () {
                        setState(() => plannerFraction = .30);
                        save();
                      },
                    ),
                    Expanded(child: calendar),
                  ],
                );
              },
            )
          : mobileTasks
          ? list
          : calendar,
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
                      final tasks = repo.snapshot.boardTasks(
                        status,
                        repo.now(),
                        projectId: projectId,
                        doneDays: boardDoneDays == 0 ? null : boardDoneDays,
                      );
                      final visibleCount = status == TaskStatus.done
                          ? math.min(boardDoneLimit, tasks.length)
                          : tasks.length;
                      final more = tasks.length - visibleCount;
                      return Container(
                        decoration: BoxDecoration(
                          color: candidates.isNotEmpty
                              ? context.accentColor.withValues(alpha: .08)
                              : context.palette.surface.withValues(alpha: .5),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: candidates.isNotEmpty
                                ? context.accentColor
                                : context.palette.border,
                            width: .6,
                          ),
                        ),
                        child: Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 17,
                                vertical: 9,
                              ),
                              child: SizedBox(
                                height: 40,
                                child: Row(
                                  children: [
                                    Container(
                                      width: 7,
                                      height: 7,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: status == TaskStatus.done
                                            ? context.palette.green
                                            : status == TaskStatus.inProgress
                                            ? context.palette.pink
                                            : status == TaskStatus.waiting
                                            ? Palette.projects[2]
                                            : context.accentColor,
                                      ),
                                    ),
                                    const SizedBox(width: 9),
                                    Expanded(
                                      child: Text(
                                        status.label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    if (status == TaskStatus.done) ...[
                                      const SizedBox(width: 8),
                                      PopupMenuButton<int>(
                                        key: const ValueKey(
                                          'board-done-period',
                                        ),
                                        tooltip: tr("Период завершённых задач"),
                                        initialValue: boardDoneDays,
                                        onSelected: (days) => setState(() {
                                          boardDoneDays = days;
                                          boardDoneLimit = 50;
                                        }),
                                        itemBuilder: (_) => [
                                          for (final days in [7, 30, 0])
                                            CheckedPopupMenuItem(
                                              value: days,
                                              checked: boardDoneDays == days,
                                              child: Text(
                                                days == 0
                                                    ? tr("Вся история")
                                                    : tr("Последние {0} дней", [
                                                        days,
                                                      ]),
                                              ),
                                            ),
                                        ],
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 8,
                                            horizontal: 4,
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                boardDoneDays == 0
                                                    ? tr("Всё время")
                                                    : tr("{0} дней", [
                                                        boardDoneDays,
                                                      ]),
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: context.palette.muted,
                                                ),
                                              ),
                                              const SizedBox(width: 3),
                                              Icon(
                                                Icons.expand_more_rounded,
                                                size: 16,
                                                color: context.palette.muted,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                    const SizedBox(width: 8),
                                    Text(
                                      '${tasks.length}',
                                      key: ValueKey(
                                        'board-count-${status.wire}',
                                      ),
                                      style: TextStyle(
                                        color: context.palette.muted,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Expanded(
                              child: status == TaskStatus.done && tasks.isEmpty
                                  ? Padding(
                                      padding: const EdgeInsets.all(20),
                                      child: Text(
                                        boardDoneDays == 0
                                            ? tr(
                                                "Здесь появятся завершённые задачи.",
                                              )
                                            : tr(
                                                "За последние {0} дней нет завершённых задач. Более ранние доступны в истории.",
                                                [boardDoneDays],
                                              ),
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 1.5,
                                          color: context.palette.muted,
                                        ),
                                      ),
                                    )
                                  : ListView.builder(
                                      key: ValueKey(
                                        'board-list-${status.wire}-$projectId-${status == TaskStatus.done ? boardDoneDays : 0}',
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                      ),
                                      itemCount:
                                          visibleCount + (more > 0 ? 1 : 0),
                                      itemBuilder: (context, i) {
                                        if (i < visibleCount) {
                                          return BoardTask(task: tasks[i]);
                                        }
                                        return Padding(
                                          padding: const EdgeInsets.only(
                                            top: 8,
                                            bottom: 16,
                                          ),
                                          child: Column(
                                            children: [
                                              Text(
                                                tr("Показано {0} из {1}", [
                                                  visibleCount,
                                                  tasks.length,
                                                ]),
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: context.palette.muted,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              TextButton(
                                                key: const ValueKey(
                                                  'board-done-more',
                                                ),
                                                onPressed: () => setState(
                                                  () => boardDoneLimit += 50,
                                                ),
                                                child: Text(
                                                  tr("Показать ещё {0}", [
                                                    math.min(50, more),
                                                  ]),
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      },
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

class _MobileCreateButton extends StatelessWidget {
  const _MobileCreateButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.primary = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 64,
    height: 64,
    child: FloatingActionButton(
      heroTag: 'create-$label',
      tooltip: tr("Создать: {0}", [label]),
      onPressed: onPressed,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 1,
      backgroundColor: primary
          ? context.accentColor
          : Color.alphaBlend(
              context.accentColor.withValues(alpha: .14),
              context.palette.surface,
            ),
      foregroundColor: primary
          ? Theme.of(context).colorScheme.onPrimary
          : context.accentColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: primary
            ? BorderSide.none
            : BorderSide(color: context.accentColor.withValues(alpha: .3)),
      ),
      child: Icon(icon, size: 28),
    ),
  );
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
  String query = '';
  Timer? debounce;
  int generation = 0;
  void find(String value) {
    debounce?.cancel();
    query = value;
    final current = ++generation;
    setState(() {
      busy = value.trim().isNotEmpty;
      error = null;
      results = [];
    });
    if (value.trim().isEmpty) return;
    debounce = Timer(const Duration(milliseconds: 180), () async {
      try {
        final repo = ref.read(appProvider);
        final next = await repo.db.search(
          value,
          maxTypos: repo.snapshot.settings.searchTypos,
        );
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

  String searchHint(int tolerance) {
    final words = searchWords(query);
    if (words.length == 1 && words.single.runes.length == 1) {
      return tr("Одна буква — точный поиск");
    }
    return switch (tolerance) {
      0 => tr("Точное совпадение · настройки → точность поиска"),
      1 => tr("Допуск: 1 опечатка в слове"),
      _ => tr("Допуск: 2 опечатки в слове"),
    };
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
              decoration: InputDecoration(
                hintText: tr("Поиск по задачам, описаниям и заметкам"),
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
          ),
          if (busy) const LinearProgressIndicator(minHeight: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                searchHint(
                  ref.watch(appProvider).snapshot.settings.searchTypos,
                ),
                style: TextStyle(color: context.palette.muted, fontSize: 12),
              ),
            ),
          ),
          const Divider(),
          Expanded(
            child: error != null
                ? Center(child: Text(error!))
                : results.isEmpty
                ? EmptyState(
                    icon: Icons.search_rounded,
                    title: busy
                        ? tr("Ищем…")
                        : query.trim().isEmpty
                        ? tr("Найдётся даже прошлое")
                        : tr("Ничего не найдено"),
                    subtitle: query.trim().isEmpty
                        ? tr(
                            "Можно начать с одной буквы.\nПоиск работает без интернета.",
                          )
                        : tr(
                            "Попробуйте другое слово или увеличьте\nдопуск ошибок в настройках.",
                          ),
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
