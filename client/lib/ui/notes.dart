import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/models.dart';
import '../domain/note_links.dart';
import 'markdown_editor.dart';
import 'providers.dart';
import 'theme.dart';

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
      if (mounted) setState(() => saveError = 'Не удалось сохранить: $e');
    }
  }

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
    final mobile = MediaQuery.sizeOf(context).width < 800;
    final readOnly = !mobile && note.pinned == 'reference' && !editing;
    final editor = LiveMarkdownEditor(
      key: editorKey,
      value: note.content,
      noteId: note.id,
      readOnly: readOnly,
      editOnLongPress: mobile,
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
                  ? 'Быстрая заметка'
                  : 'Справочная заметка',
              child: Icon(
                note.pinned == 'scratchpad'
                    ? Icons.edit_note_rounded
                    : Icons.bookmark_outline_rounded,
                color: context.palette.muted,
                size: 19,
              ),
            ),
      toolbarTrailing: mobile && editing
          ? TextButton(
              key: ValueKey('finish-note-${note.id}'),
              onPressed: () => editorKey.currentState?.finishEditing(),
              child: const Text('Готово'),
            )
          : !mobile && note.pinned == 'reference'
          ? TextButton(
              onPressed: () {
                if (editing) editorKey.currentState?.finishEditing();
                setState(() => editing = !editing);
              },
              child: Text(editing ? 'Готово' : 'Изменить'),
            )
          : null,
      placeholder: mobile && !editing
          ? 'Удерживайте, чтобы начать писать…'
          : note.pinned == 'scratchpad'
          ? 'Черновики, конфиги, файлы — просто начните писать…'
          : 'Идеи, ссылки и всё, что важно сохранить…',
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
                decoration: const InputDecoration(
                  hintText: 'Название · необязательно',
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
  const NotesPage({super.key, this.initialId, this.editId});
  final String? initialId, editId;
  @override
  ConsumerState<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends ConsumerState<NotesPage> {
  String? selected;
  String? pendingEdit;
  final mobileScroll = ScrollController();
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
    });
    if (mobileScroll.hasClients) mobileScroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(appProvider);
    final regular = [
      ...repo.snapshot.notesInFolder(''),
      for (final folder in repo.snapshot.noteFolders)
        ...repo.snapshot.notesInFolder(folder.id),
    ];
    final mobile = MediaQuery.sizeOf(context).width < 800;
    if (mobile) {
      final opened = regular.where((note) => note.id == selected).firstOrNull;
      return ListView(
        key: const ValueKey('mobile-notes-list'),
        controller: mobileScroll,
        padding: const EdgeInsets.all(16),
        children: [
          if (opened != null) ...[
            NotePanel(
              key: ValueKey(opened.id),
              noteId: opened.id,
              autofocus: pendingEdit == opened.id,
              onAutofocus: () => setState(() => pendingEdit = null),
            ),
            const SizedBox(height: 14),
          ],
          Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text(
              'Удерживайте текст заметки, чтобы редактировать',
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
          ),
          const NotePanel(noteId: 'scratchpad'),
          const SizedBox(height: 14),
          const NotePanel(noteId: 'reference'),
          const SizedBox(height: 18),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Заметки',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.folder_outlined, size: 18),
                label: const Text('Папки и порядок'),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (sheet) => SizedBox(
                    height: MediaQuery.sizeOf(sheet).height * .75,
                    child: SafeArea(
                      child: NoteLibrary(
                        selected: selected,
                        onSelect: (id) {
                          Navigator.pop(sheet);
                          openNote(id);
                        },
                        onCreate: (id) {
                          Navigator.pop(sheet);
                          openNote(id, edit: true);
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final note in regular.where(
            (note) => note.id != opened?.id,
          )) ...[
            NotePanel(key: ValueKey(note.id), noteId: note.id),
            const SizedBox(height: 12),
          ],
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

  Future<void> editFolder([NoteFolder? folder]) async {
    final controller = TextEditingController(text: folder?.title ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(folder == null ? 'Новая папка' : 'Название папки'),
        content: TextField(
          autofocus: true,
          controller: controller,
          maxLength: 250,
          decoration: const InputDecoration(hintText: 'Например, Работа'),
          onSubmitted: (value) => Navigator.pop(dialog, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, controller.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    // The route's exit animation may still use its controller.
    Future<void>.delayed(const Duration(milliseconds: 300), controller.dispose);
    if (value != null && mounted) {
      await guard(
        context,
        () => ref.read(appProvider).saveNoteFolder(value, folder: folder),
      );
    }
  }

  Future<void> noteAction(String action, Note note) => guard(context, () async {
    final repo = ref.read(appProvider);
    if (action.startsWith('folder:')) {
      await repo.moveNote(note.id, action.substring(7));
    } else if (action == 'copy') {
      await Clipboard.setData(
        ClipboardData(text: WikiNoteIndex(repo.snapshot).linkFor(note)),
      );
    } else if (action == 'delete') {
      final yes = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Удалить заметку?'),
          content: Text(note.displayLabel),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Удалить'),
            ),
          ],
        ),
      );
      if (yes == true) await repo.deleteEntity(note.entity);
    }
  });

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
      tooltip: 'Действия с заметкой',
      padding: EdgeInsets.zero,
      iconSize: 18,
      onSelected: (action) => noteAction(action, note),
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'copy', child: Text('Скопировать ссылку')),
        if (note.pinned.isEmpty) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: 'folder:',
            child: Text('Переместить → Без папки'),
          ),
          for (final folder in ref.read(appProvider).snapshot.noteFolders)
            PopupMenuItem(
              value: 'folder:${folder.id}',
              child: Text('Переместить → ${folder.title}'),
            ),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'delete', child: Text('Удалить заметку')),
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
                  '${notes.length} заметок',
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
                  tooltip: 'Действия с папкой',
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
                          title: const Text('Удалить папку?'),
                          content: const Text(
                            'Заметки останутся в разделе «Без папки».',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dialog, false),
                              child: const Text('Отмена'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(dialog, true),
                              child: const Text('Удалить папку'),
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
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'create',
                      child: Text('Создать заметку'),
                    ),
                    PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'rename',
                      child: Text('Переименовать'),
                    ),
                    PopupMenuItem(value: 'up', child: Text('Поднять')),
                    PopupMenuItem(value: 'down', child: Text('Опустить')),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text('Удалить папку'),
                    ),
                  ],
                ),
        ),
        if (!collapsed.contains(id))
          if (notes.isEmpty)
            Padding(
              padding: EdgeInsets.only(left: 26, bottom: 12),
              child: Text(
                'Пока пусто',
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
                'БИБЛИОТЕКА',
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
              tooltip: 'Создать папку',
              icon: const Icon(Icons.create_new_folder_outlined, size: 19),
            ),
          ],
        ),
        for (final note in snapshot.notes.where((n) => n.pinned.isNotEmpty))
          tile(note),
        const Divider(height: 24),
        group('', 'Без папки'),
        for (final folder in snapshot.noteFolders)
          group(folder.id, folder.title, folder: folder),
      ],
    );
  }
}
