import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/models.dart';
import 'markdown_editor.dart';
import 'providers.dart';
import 'theme.dart';

Future<void> editNoteTitle(
  BuildContext context,
  WidgetRef ref,
  Note note,
) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _NoteTitleDialog(title: note.title),
  );
  if (name == null || !context.mounted) return;
  await guard(context, () async {
    final repo = ref.read(appProvider);
    final current = repo.snapshot.notes
        .where((n) => n.id == note.id)
        .firstOrNull;
    if (current != null) await repo.saveNote(current.id, name, current.content);
  });
}

class _NoteTitleDialog extends StatefulWidget {
  const _NoteTitleDialog({required this.title});
  final String title;
  @override
  State<_NoteTitleDialog> createState() => _NoteTitleDialogState();
}

class _NoteTitleDialogState extends State<_NoteTitleDialog> {
  late final controller = TextEditingController(text: widget.title)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.title.length,
    );
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Название заметки'),
    content: TextField(
      key: const ValueKey('note-title'),
      controller: controller,
      autofocus: true,
      textInputAction: TextInputAction.done,
      onSubmitted: (value) => Navigator.pop(context, value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, controller.text),
        child: const Text('Сохранить'),
      ),
    ],
  );
}

class NotePanel extends ConsumerStatefulWidget {
  const NotePanel({
    super.key,
    required this.noteId,
    this.compact = false,
    this.fill = false,
  });
  final String noteId;
  final bool compact, fill;
  @override
  ConsumerState<NotePanel> createState() => _NotePanelState();
}

class _NotePanelState extends ConsumerState<NotePanel> {
  final editorKey = GlobalKey<LiveMarkdownEditorState>();
  bool editing = false;
  String? saveError;
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
      placeholder: mobile
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
            Row(
              children: [
                Icon(
                  note.pinned == 'scratchpad'
                      ? Icons.edit_note_rounded
                      : note.pinned == 'reference'
                      ? Icons.bookmark_outline_rounded
                      : Icons.description_outlined,
                  color: Palette.muted,
                  size: 19,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    note.title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (mobile && editing)
                  TextButton(
                    key: ValueKey('finish-note-${note.id}'),
                    onPressed: () => editorKey.currentState?.finishEditing(),
                    child: const Text('Готово'),
                  )
                else if (!mobile && note.pinned == 'reference')
                  TextButton(
                    onPressed: () {
                      if (editing) editorKey.currentState?.finishEditing();
                      setState(() => editing = !editing);
                    },
                    child: Text(editing ? 'Готово' : 'Изменить'),
                  ),
                if (note.pinned.isEmpty)
                  IconButton(
                    tooltip: 'Переименовать',
                    onPressed: () => editNoteTitle(context, ref, note),
                    icon: const Icon(Icons.more_horiz_rounded, size: 18),
                  ),
              ],
            ),
            const SizedBox(height: 8),
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
  const NotesPage({super.key, this.initialId});
  final String? initialId;
  @override
  ConsumerState<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends ConsumerState<NotesPage> {
  String? selected;
  @override
  void initState() {
    super.initState();
    selected = widget.initialId;
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(appProvider);
    final regular = repo.snapshot.notes.where((n) => n.pinned.isEmpty).toList();
    final mobile = MediaQuery.sizeOf(context).width < 800;
    if (mobile) {
      return ListView(
        key: const ValueKey('mobile-notes-list'),
        padding: const EdgeInsets.all(16),
        children: [
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
          Row(
            children: [
              const Text(
                'Заметки',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Новая заметка',
                onPressed: () => guard(context, () async {
                  final note = await repo.createNote();
                  if (context.mounted) await editNoteTitle(context, ref, note);
                }),
                icon: const Icon(Icons.add_rounded),
              ),
            ],
          ),
          for (final note in regular) ...[
            NotePanel(key: ValueKey(note.id), noteId: note.id),
            const SizedBox(height: 12),
          ],
        ],
      );
    }
    final id = selected ?? 'scratchpad';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 245,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.tonalIcon(
                  onPressed: () => guard(context, () async {
                    final n = await repo.createNote();
                    if (!context.mounted) return;
                    setState(() => selected = n.id);
                    await editNoteTitle(context, ref, n);
                  }),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Новая заметка'),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  children: [
                    for (final note in [
                      ...repo.snapshot.notes.where((n) => n.pinned.isNotEmpty),
                      ...regular,
                    ])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: ListTile(
                          dense: true,
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
                            note.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => setState(() => selected = note.id),
                          trailing: note.pinned.isEmpty
                              ? IconButton(
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
                                        content: Text(note.title),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(c, false),
                                            child: const Text('Отмена'),
                                          ),
                                          FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(c, true),
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
                  ],
                ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: NotePanel(key: ValueKey(id), noteId: id),
          ),
        ),
      ],
    );
  }
}
