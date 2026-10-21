import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/models.dart';
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
  bool editing = false;
  String? saveError;

  @override
  void initState() {
    super.initState();
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        editorKey.currentState?.focusEditor();
        widget.onAutofocus?.call();
      });
    }
  }

  Future<void> save(Note note, String content) async {
    try {
      await ref.read(appProvider).saveNote(note.id, note.title, content);
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
    final mobile = MediaQuery.sizeOf(context).width < 800;
    final readOnly = !mobile && note.pinned == 'reference' && !editing;
    final editor = LiveMarkdownEditor(
      key: editorKey,
      value: note.content,
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
                color: Palette.muted,
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
  @override
  void initState() {
    super.initState();
    selected = widget.initialId;
    pendingEdit = widget.editId;
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(appProvider);
    final regular = repo.snapshot.notes.where((n) => n.pinned.isEmpty).toList();
    final mobile = MediaQuery.sizeOf(context).width < 800;
    if (mobile) {
      final opened = regular.where((note) => note.id == selected).firstOrNull;
      return ListView(
        key: const ValueKey('mobile-notes-list'),
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
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text(
              'Удерживайте текст заметки, чтобы редактировать',
              style: TextStyle(color: Palette.muted, fontSize: 12),
            ),
          ),
          const NotePanel(noteId: 'scratchpad'),
          const SizedBox(height: 14),
          const NotePanel(noteId: 'reference'),
          const SizedBox(height: 18),
          const Text(
            'Заметки',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
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
          width: 232,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
            children: [
              for (final note in [
                ...repo.snapshot.notes.where((n) => n.pinned.isNotEmpty),
                ...regular,
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Tooltip(
                    message: note.displayLabel,
                    waitDuration: const Duration(milliseconds: 600),
                    child: ListTile(
                      key: ValueKey('note-list-${note.id}'),
                      dense: true,
                      minTileHeight: 40,
                      minVerticalPadding: 0,
                      minLeadingWidth: 18,
                      horizontalTitleGap: 8,
                      contentPadding: const EdgeInsets.only(left: 10, right: 4),
                      visualDensity: VisualDensity.compact,
                      selected: id == note.id,
                      selectedTileColor: context.accentColor.withValues(
                        alpha: .08,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      leading: Icon(
                        note.pinned.isEmpty
                            ? Icons.description_outlined
                            : Icons.push_pin_outlined,
                        size: 17,
                      ),
                      title: Text(
                        note.displayLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, height: 1.2),
                      ),
                      onTap: () => setState(() => selected = note.id),
                      trailing: note.pinned.isEmpty
                          ? IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              visualDensity: VisualDensity.compact,
                              tooltip: 'Удалить заметку',
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                size: 16,
                              ),
                              onPressed: () => guard(context, () async {
                                final yes = await showDialog<bool>(
                                  context: context,
                                  builder: (c) => AlertDialog(
                                    title: const Text('Удалить заметку?'),
                                    content: Text(note.displayLabel),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(c, false),
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
                                  await repo.deleteEntity(note.entity);
                                  if (mounted) {
                                    setState(() => selected = null);
                                  }
                                }
                              }),
                            )
                          : null,
                    ),
                  ),
                ),
            ],
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
