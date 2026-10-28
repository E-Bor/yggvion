import '../l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/models.dart';
import '../domain/note_links.dart';
import 'markdown_editor.dart';
import 'attachments.dart';
import 'providers.dart';
import 'theme.dart';

Future<void> _confirmNoteRemoval(
  BuildContext context,
  WidgetRef ref,
  Note note,
) => guard(context, () async {
  final repo = ref.read(appProvider);
  final clearOnly = note.pinned.isNotEmpty;
  FocusManager.instance.primaryFocus?.unfocus();
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(clearOnly ? tr("Очистить заметку?") : tr("Удалить заметку?")),
      content: Text(
        clearOnly
            ? tr("Удалится только содержимое. Заметка останется на месте.")
            : note.displayLabel,
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog, false),
          child: Text(tr("Отмена")),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(dialog).colorScheme.error,
            foregroundColor: Theme.of(dialog).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(clearOnly ? tr("Очистить") : tr("Удалить")),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  if (clearOnly) {
    await repo.saveNoteContent(note.id, '');
  } else {
    await repo.deleteEntity(note.entity);
  }
});

Future<void> editNoteFolder(
  BuildContext context,
  WidgetRef ref, [
  NoteFolder? folder,
]) async {
  final repo = ref.read(appProvider);
  final controller = TextEditingController(text: folder?.title ?? '');
  final value = await showDialog<String>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(folder == null ? tr("Новая папка") : tr("Название папки")),
      content: TextField(
        key: const ValueKey('folder-name'),
        autofocus: true,
        controller: controller,
        maxLength: 250,
        decoration: InputDecoration(hintText: tr("Например, Работа")),
        onSubmitted: (value) => Navigator.pop(dialog, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: Text(tr("Отмена")),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialog, controller.text),
          child: Text(tr("Сохранить")),
        ),
      ],
    ),
  );
  Future<void>.delayed(const Duration(milliseconds: 300), controller.dispose);
  if (value != null && context.mounted) {
    await guard(context, () => repo.saveNoteFolder(value, folder: folder));
  }
}

Future<void> moveNoteToFolder(
  BuildContext context,
  WidgetRef ref,
  Note note,
) async {
  FocusManager.instance.primaryFocus?.unfocus();
  final repo = ref.read(appProvider);
  final target = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.all(16),
            child: Text(tr("Переместить в папку")),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final folder in [
                  (id: '', title: tr("Без папки")),
                  ...repo.snapshot.noteFolders.map(
                    (folder) => (id: folder.id, title: folder.title),
                  ),
                ])
                  ListTile(
                    key: ValueKey('move-note-folder-${folder.id}'),
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(folder.title),
                    trailing: note.folderId == folder.id
                        ? const Icon(Icons.check_rounded)
                        : null,
                    onTap: () => Navigator.pop(sheet, folder.id),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  if (target != null && context.mounted) {
    await guard(context, () => repo.moveNote(note.id, target));
  }
}

class NotePanel extends ConsumerStatefulWidget {
  const NotePanel({
    super.key,
    required this.noteId,
    this.compact = false,
    this.fill = false,
    this.autofocus = false,
    this.onAutofocus,
  });
  final String noteId;
  final bool compact, fill, autofocus;
  final VoidCallback? onAutofocus;
  @override
  ConsumerState<NotePanel> createState() => _NotePanelState();
}

class _NotePanelState extends ConsumerState<NotePanel> {
  final editorKey = GlobalKey<LiveMarkdownEditorState>();
  final titleController = TextEditingController();
  final titleFocus = FocusNode();
  bool editing = false;
  String? saveError;

  @override
  void initState() {
    super.initState();
    titleController.text =
        ref.read(appProvider).snapshot.note(widget.noteId)?.explicitTitle ?? '';
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        editorKey.currentState?.focusEditor();
        widget.onAutofocus?.call();
      });
    }
  }

  @override
  void dispose() {
    titleController.dispose();
    titleFocus.dispose();
    super.dispose();
  }

  Future<void> save(Note note, String content) async {
    try {
      await ref.read(appProvider).saveNoteContent(note.id, content);
      if (mounted && saveError != null) setState(() => saveError = null);
    } catch (e) {
      if (mounted) {
        setState(() => saveError = tr("Не удалось сохранить: {0}", [e]));
      }
    }
  }

  Widget noteMenu(Note note) => SizedBox.square(
    dimension: 44,
    child: PopupMenuButton<String>(
      key: ValueKey('note-actions-${note.id}'),
      tooltip: tr("Действия с заметкой"),
      padding: EdgeInsets.zero,
      icon: Icon(
        Icons.more_horiz_rounded,
        size: 21,
        color: context.palette.muted,
      ),
      onOpened: () => FocusManager.instance.primaryFocus?.unfocus(),
      onSelected: (action) => action == 'move'
          ? moveNoteToFolder(context, ref, note)
          : _confirmNoteRemoval(context, ref, note),
      itemBuilder: (context) => [
        if (note.pinned.isEmpty) ...[
          PopupMenuItem(value: 'move', child: Text(tr("Переместить в папку"))),
          const PopupMenuDivider(),
        ],
        PopupMenuItem(
          value: note.pinned.isEmpty ? 'delete' : 'clear',
          child: Row(
            children: [
              Icon(
                note.pinned.isEmpty
                    ? Icons.delete_outline_rounded
                    : Icons.cleaning_services_outlined,
                size: 20,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  note.pinned.isEmpty
                      ? tr("Удалить заметку")
                      : tr("Очистить содержимое"),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final note = ref
        .watch(appProvider)
        .snapshot
        .notes
        .where((n) => n.id == widget.noteId)
        .firstOrNull;
    if (note == null) return const SizedBox.shrink();
    if (!titleFocus.hasFocus && titleController.text != note.explicitTitle) {
      titleController.text = note.explicitTitle;
    }
    final mobile = usesMobileLayout(context);
    final readOnly = !mobile && note.pinned == 'reference' && !editing;
    final editor = LiveMarkdownEditor(
      key: editorKey,
      value: note.content,
      noteId: note.id,
      readOnly: readOnly,
      continuousInput: mobile,
      onEditingChanged: mobile
          ? (value) {
              if (mounted && editing != value) {
                setState(() => editing = value);
              }
            }
          : null,
      toolbar: !widget.compact || editing,
      toolbarLabel: '',
      toolbarLeading: note.pinned.isEmpty
          ? null
          : Tooltip(
              message: note.pinned == 'scratchpad'
                  ? tr("Быстрая заметка")
                  : tr("Справочная заметка"),
              child: Icon(
                note.pinned == 'scratchpad'
                    ? Icons.edit_note_rounded
                    : Icons.bookmark_outline_rounded,
                color: context.palette.muted,
                size: 19,
              ),
            ),
      toolbarTrailing: mobile && note.pinned.isNotEmpty
          ? noteMenu(note)
          : !mobile && note.pinned == 'reference'
          ? TextButton(
              onPressed: () {
                if (editing) editorKey.currentState?.finishEditing();
                setState(() => editing = !editing);
              },
              child: Text(editing ? tr("Готово") : tr("Изменить")),
            )
          : null,
      placeholder: note.pinned == 'scratchpad'
          ? tr("Черновики, конфиги, файлы — просто начните писать…")
          : tr("Идеи, ссылки и всё, что важно сохранить…"),
      onChanged: (v) => save(note, v),
    );
    return Card(
      child: Padding(
        padding: EdgeInsets.all(
          widget.fill
              ? 16
              : widget.compact
              ? 18
              : 24,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (note.pinned.isEmpty) ...[
              TextField(
                key: ValueKey('note-title-${note.id}'),
                controller: titleController,
                focusNode: titleFocus,
                maxLength: 250,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
                decoration: InputDecoration(
                  hintText: mobile
                      ? tr("Название")
                      : tr("Название · необязательно"),
                  suffixIcon: mobile ? noteMenu(note) : null,
                  suffixIconConstraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  counterText: '',
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
                onTapOutside: (_) => titleFocus.unfocus(),
                onSubmitted: (_) => editorKey.currentState?.focusEditor(),
                onChanged: (value) => guard(
                  context,
                  () => ref.read(appProvider).renameNote(note.id, value),
                ),
              ),
              const Divider(height: 1),
              const SizedBox(height: 10),
            ],
            if (widget.fill)
              Expanded(child: SingleChildScrollView(child: editor))
            else
              editor,
            if (saveError != null)
              Text(
                saveError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }
}

class NotesPage extends ConsumerStatefulWidget {
  const NotesPage({
    super.key,
    this.initialId,
    this.editId,
    this.keyboardVisible = false,
  });
  final bool keyboardVisible;
  final String? initialId, editId;
  @override
  ConsumerState<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends ConsumerState<NotesPage> {
  String? selected;
  String? pendingEdit;
  final mobileScroll = ScrollController();
  final collapsedFolders = <String>{};
  @override
  void initState() {
    super.initState();
    selected = widget.initialId;
    pendingEdit = widget.editId;
    if (selected != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(selectedNoteFolderProvider.notifier).state =
            ref.read(appProvider).snapshot.note(selected!)?.folderId ?? '';
      });
    }
  }

  @override
  void dispose() {
    mobileScroll.dispose();
    super.dispose();
  }

  void openNote(String id, {bool edit = false}) {
    setState(() {
      selected = id;
      pendingEdit = edit ? id : null;
      collapsedFolders.remove(
        ref.read(appProvider).snapshot.note(id)?.folderId ?? '',
      );
    });
    if (mobileScroll.hasClients) mobileScroll.jumpTo(0);
  }

  Future<void> createInFolder(String id) => guard(context, () async {
    final note = await ref.read(appProvider).createNote(folderId: id);
    if (!mounted) return;
    ref.read(selectedNoteFolderProvider.notifier).state = id;
    collapsedFolders.remove(id);
    openNote(note.id, edit: true);
  });

  List<Widget> mobileGroup(
    String id,
    String title, {
    NoteFolder? folder,
    String? focusedId,
  }) {
    final repo = ref.read(appProvider);
    final notes = repo.snapshot.notesInFolder(id);
    final shown = [
      ...notes.where((note) => note.id == focusedId),
      ...notes.where((note) => note.id != focusedId),
    ];
    return [
      Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 8),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                key: ValueKey('note-folder-$id'),
                borderRadius: BorderRadius.circular(10),
                onTap: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  ref.read(selectedNoteFolderProvider.notifier).state = id;
                  setState(
                    () => collapsedFolders.contains(id)
                        ? collapsedFolders.remove(id)
                        : collapsedFolders.add(id),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 4,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        collapsedFolders.contains(id)
                            ? Icons.chevron_right_rounded
                            : Icons.expand_more_rounded,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      Text(
                        '${notes.length}',
                        style: TextStyle(
                          color: context.palette.muted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              key: ValueKey('folder-create-note-$id'),
              tooltip: tr("Создать заметку в папке"),
              icon: const Icon(Icons.note_add_outlined, size: 20),
              onPressed: () => createInFolder(id),
            ),
            if (folder != null)
              PopupMenuButton<String>(
                key: ValueKey('folder-actions-$id'),
                tooltip: tr("Действия с папкой"),
                icon: const Icon(Icons.more_horiz_rounded, size: 20),
                onSelected: (action) => guard(context, () async {
                  if (action == 'rename') {
                    await editNoteFolder(context, ref, folder);
                  } else if (action == 'delete') {
                    final yes = await showDialog<bool>(
                      context: context,
                      builder: (dialog) => AlertDialog(
                        title: Text(tr("Удалить папку?")),
                        content: Text(
                          tr("Заметки останутся в разделе «Без папки»."),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialog, false),
                            child: Text(tr("Отмена")),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(dialog, true),
                            child: Text(tr("Удалить папку")),
                          ),
                        ],
                      ),
                    );
                    if (yes == true) await repo.deleteNoteFolder(folder);
                  } else {
                    final ids = repo.snapshot.noteFolders
                        .map((f) => f.id)
                        .toList();
                    final index = ids.indexOf(id);
                    final next = index + (action == 'up' ? -1 : 1);
                    if (index < 0 || next < 0 || next >= ids.length) return;
                    ids[index] = ids[next];
                    ids[next] = id;
                    await repo.reorderNoteFolders(ids);
                  }
                }),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'rename',
                    child: Text(tr("Переименовать")),
                  ),
                  PopupMenuItem(value: 'up', child: Text(tr("Поднять"))),
                  PopupMenuItem(value: 'down', child: Text(tr("Опустить"))),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(tr("Удалить папку")),
                  ),
                ],
              ),
          ],
        ),
      ),
      if (!collapsedFolders.contains(id))
        for (final note in shown) ...[
          NotePanel(
            key: ValueKey(note.id),
            noteId: note.id,
            autofocus: pendingEdit == note.id,
            onAutofocus: () => setState(() => pendingEdit = null),
          ),
          const SizedBox(height: 12),
        ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(appProvider);
    final regular = [
      ...repo.snapshot.notesInFolder(''),
      for (final folder in repo.snapshot.noteFolders)
        ...repo.snapshot.notesInFolder(folder.id),
    ];
    final mobile = usesMobileLayout(context);
    if (mobile) {
      final opened = regular.where((note) => note.id == selected).firstOrNull;
      final notes = ListView(
        key: const ValueKey('mobile-notes-list'),
        controller: mobileScroll,
        padding: const EdgeInsets.all(16),
        children: [
          if (opened != null)
            ...mobileGroup(
              opened.folderId,
              repo.snapshot.noteFolders
                      .where((f) => f.id == opened.folderId)
                      .firstOrNull
                      ?.title ??
                  tr("Без папки"),
              folder: repo.snapshot.noteFolders
                  .where((f) => f.id == opened.folderId)
                  .firstOrNull,
              focusedId: opened.id,
            ),
          const NotePanel(noteId: 'scratchpad'),
          const SizedBox(height: 14),
          const NotePanel(noteId: 'reference'),
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tr("Заметки"),
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  key: const ValueKey('create-note-folder'),
                  tooltip: tr("Создать папку"),
                  icon: const Icon(Icons.create_new_folder_outlined, size: 21),
                  onPressed: () => editNoteFolder(context, ref),
                ),
              ],
            ),
          ),
          if (opened?.folderId != '') ...mobileGroup('', tr("Без папки")),
          for (final folder in repo.snapshot.noteFolders)
            if (folder.id != opened?.folderId)
              ...mobileGroup(folder.id, folder.title, folder: folder),
        ],
      );
      return Column(
        children: [
          Expanded(child: notes),
          if (widget.keyboardVisible)
            Container(
              key: const ValueKey('notes-keyboard-bar'),
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: context.palette.surface,
                border: Border(
                  top: BorderSide(color: context.palette.border, width: .5),
                ),
              ),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const ValueKey('notes-keyboard-done'),
                  style: TextButton.styleFrom(minimumSize: const Size(76, 44)),
                  onPressed: () =>
                      FocusManager.instance.primaryFocus?.unfocus(),
                  child: Text(tr("Готово")),
                ),
              ),
            ),
        ],
      );
    }
    final id = repo.snapshot.notes.any((note) => note.id == selected)
        ? selected!
        : 'scratchpad';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 256,
          child: NoteLibrary(
            selected: id,
            onSelect: openNote,
            onCreate: (id) => openNote(id, edit: true),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: NotePanel(
              key: ValueKey(id),
              noteId: id,
              autofocus: pendingEdit == id,
              onAutofocus: () => setState(() => pendingEdit = null),
            ),
          ),
        ),
      ],
    );
  }
}

class NoteLibrary extends ConsumerStatefulWidget {
  const NoteLibrary({
    super.key,
    this.selected,
    required this.onSelect,
    required this.onCreate,
  });
  final String? selected;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onCreate;
  @override
  ConsumerState<NoteLibrary> createState() => _NoteLibraryState();
}

class _NoteLibraryState extends ConsumerState<NoteLibrary> {
  final collapsed = <String>{};

  Future<void> createInFolder(String id) => guard(context, () async {
    final note = await ref.read(appProvider).createNote(folderId: id);
    if (!mounted) return;
    ref.read(selectedNoteFolderProvider.notifier).state = id;
    setState(() => collapsed.remove(id));
    widget.onCreate(note.id);
  });

  Future<void> editFolder([NoteFolder? folder]) =>
      editNoteFolder(context, ref, folder);

  Future<void> noteAction(String action, Note note) {
    if (action == 'delete') return _confirmNoteRemoval(context, ref, note);
    return guard(context, () async {
      final repo = ref.read(appProvider);
      if (action.startsWith('folder:')) {
        await repo.moveNote(note.id, action.substring(7));
      } else if (action == 'copy') {
        await Clipboard.setData(
          ClipboardData(text: WikiNoteIndex(repo.snapshot).linkFor(note)),
        );
      }
    });
  }

  Widget tile(Note note, {int? index}) => ListTile(
    key: ValueKey('note-list-${note.id}'),
    dense: true,
    minTileHeight: 42,
    minVerticalPadding: 0,
    minLeadingWidth: 18,
    horizontalTitleGap: 8,
    contentPadding: const EdgeInsets.only(left: 8, right: 0),
    selected: widget.selected == note.id,
    selectedTileColor: context.accentColor.withValues(alpha: .10),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    leading: index == null
        ? const Icon(Icons.push_pin_outlined, size: 17)
        : ReorderableDragStartListener(
            index: index,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Icon(
                  Icons.drag_indicator_rounded,
                  size: 18,
                  color: context.palette.muted,
                ),
              ),
            ),
          ),
    title: Tooltip(
      message: note.displayLabel,
      child: Text(
        note.displayLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, height: 1.2),
      ),
    ),
    onTap: () {
      ref.read(selectedNoteFolderProvider.notifier).state = note.folderId;
      widget.onSelect(note.id);
    },
    trailing: PopupMenuButton<String>(
      tooltip: tr("Действия с заметкой"),
      padding: EdgeInsets.zero,
      iconSize: 18,
      onSelected: (action) => noteAction(action, note),
      itemBuilder: (_) => [
        PopupMenuItem(value: 'copy', child: Text(tr("Скопировать ссылку"))),
        if (note.pinned.isEmpty) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'folder:',
            child: Text(tr("Переместить → Без папки")),
          ),
          for (final folder in ref.read(appProvider).snapshot.noteFolders)
            PopupMenuItem(
              value: 'folder:${folder.id}',
              child: Text(tr("Переместить → {0}", [folder.title])),
            ),
          const PopupMenuDivider(),
          PopupMenuItem(value: 'delete', child: Text(tr("Удалить заметку"))),
        ],
      ],
    ),
  );

  Widget group(String id, String title, {NoteFolder? folder}) {
    final repo = ref.read(appProvider);
    final notes = repo.snapshot.notesInFolder(id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          key: ValueKey('note-folder-$id'),
          dense: true,
          minTileHeight: 42,
          contentPadding: const EdgeInsets.only(left: 4),
          selected: ref.watch(selectedNoteFolderProvider) == id,
          selectedTileColor: context.accentColor.withValues(alpha: .07),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          leading: Icon(
            collapsed.contains(id)
                ? Icons.chevron_right_rounded
                : Icons.expand_more_rounded,
            size: 18,
          ),
          minLeadingWidth: 18,
          horizontalTitleGap: 4,
          title: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          subtitle: collapsed.contains(id)
              ? Text(
                  tr("{0} заметок", [notes.length]),
                  style: const TextStyle(fontSize: 11),
                )
              : null,
          onTap: () {
            ref.read(selectedNoteFolderProvider.notifier).state = id;
            setState(
              () => collapsed.contains(id)
                  ? collapsed.remove(id)
                  : collapsed.add(id),
            );
          },
          trailing: folder == null
              ? null
              : PopupMenuButton<String>(
                  iconSize: 17,
                  tooltip: tr("Действия с папкой"),
                  onSelected: (action) => guard(context, () async {
                    if (action == 'create') {
                      await createInFolder(id);
                      return;
                    }
                    if (action == 'rename') {
                      await editFolder(folder);
                      return;
                    }
                    if (action == 'delete') {
                      final yes = await showDialog<bool>(
                        context: context,
                        builder: (dialog) => AlertDialog(
                          title: Text(tr("Удалить папку?")),
                          content: Text(
                            tr("Заметки останутся в разделе «Без папки»."),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dialog, false),
                              child: Text(tr("Отмена")),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(dialog, true),
                              child: Text(tr("Удалить папку")),
                            ),
                          ],
                        ),
                      );
                      if (yes == true) await repo.deleteNoteFolder(folder);
                      return;
                    }
                    final ids = repo.snapshot.noteFolders
                        .map((f) => f.id)
                        .toList();
                    final index = ids.indexOf(id),
                        next = action == 'up'
                            ? ids.indexOf(id) - 1
                            : ids.indexOf(id) + 1;
                    if (next < 0 || next >= ids.length) return;
                    ids[index] = ids[next];
                    ids[next] = id;
                    await repo.reorderNoteFolders(ids);
                  }),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'create',
                      child: Text(tr("Создать заметку")),
                    ),
                    PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'rename',
                      child: Text(tr("Переименовать")),
                    ),
                    PopupMenuItem(value: 'up', child: Text(tr("Поднять"))),
                    PopupMenuItem(value: 'down', child: Text(tr("Опустить"))),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(tr("Удалить папку")),
                    ),
                  ],
                ),
        ),
        if (!collapsed.contains(id))
          if (notes.isEmpty)
            Padding(
              padding: EdgeInsets.only(left: 26, bottom: 12),
              child: Text(
                tr("Пока пусто"),
                style: TextStyle(color: context.palette.muted, fontSize: 12),
              ),
            )
          else
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorder: (old, next) {
                final moved = [...notes];
                if (next > old) next--;
                final note = moved.removeAt(old);
                moved.insert(next, note);
                guard(
                  context,
                  () => repo.moveNote(
                    note.id,
                    id,
                    beforeId: next + 1 < moved.length
                        ? moved[next + 1].id
                        : null,
                  ),
                );
              },
              children: [
                for (var i = 0; i < notes.length; i++) tile(notes[i], index: i),
              ],
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(appProvider).snapshot;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
      children: [
        Row(
          children: [
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                tr("БИБЛИОТЕКА"),
                style: TextStyle(
                  color: context.palette.muted,
                  fontSize: 10,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              onPressed: editFolder,
              tooltip: tr("Создать папку"),
              icon: const Icon(Icons.create_new_folder_outlined, size: 19),
            ),
          ],
        ),
        for (final note in snapshot.notes.where((n) => n.pinned.isNotEmpty))
          tile(note),
        ListTile(
          dense: true,
          minTileHeight: 42,
          minVerticalPadding: 0,
          minLeadingWidth: 18,
          horizontalTitleGap: 8,
          contentPadding: const EdgeInsets.only(left: 8, right: 0),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          leading: const Icon(Icons.attach_file_rounded, size: 17),
          title: Text(
            tr("Вложения"),
            style: TextStyle(fontSize: 13, height: 1.2),
          ),
          onTap: () => openAttachments(context),
        ),
        const Divider(height: 24),
        group('', tr("Без папки")),
        for (final folder in snapshot.noteFolders)
          group(folder.id, folder.title, folder: folder),
      ],
    );
  }
}
