import '../l10n/strings.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown/markdown.dart' as md;
import 'attachment_viewer.dart';
import 'package:url_launcher/url_launcher.dart';
import '../data/clipboard.dart';
import '../domain/models.dart';
import '../domain/markdown_blocks.dart';
import '../domain/markdown_links.dart';
import '../domain/markdown_tasks.dart';
import 'markdown_tasks.dart';
import 'markdown_live_controller.dart';
import 'markdown_code_block.dart';
import '../domain/note_links.dart';
import 'providers.dart';
import 'theme.dart';
import 'wiki_autocomplete.dart';

void _openMarkdownLink(BuildContext context, WidgetRef ref, String href) {
  guard(context, () async {
    final uri = Uri.parse(href);
    if (uri.scheme == 'wiki') {
      await _openWikiLink(context, ref, Uri.decodeComponent(uri.path));
    } else if (uri.scheme == 'note' ||
        (uri.scheme == 'yggvion' && uri.host == 'note')) {
      await showNotePreview(context, uri.path.replaceFirst(RegExp(r'^/'), ''));
    } else if (uri.scheme == 'attachment') {
      await openAttachment(context, uri.path);
    } else if (['https', 'http', 'mailto'].contains(uri.scheme)) {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw StateError(tr("Не удалось открыть ссылку"));
      }
    } else {
      throw StateError(tr("Этот тип ссылки пока не поддерживается"));
    }
  });
}

class MarkdownPreview extends ConsumerWidget {
  const MarkdownPreview({
    super.key,
    required this.text,
    this.selectable = true,
    this.onChanged,
  });
  final String text;
  final bool selectable;
  final ValueChanged<String>? onChanged;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final legacy = RegExp(
      r'^\[([^\]]*)\]\(note:([a-zA-Z0-9_-]+)\)$',
    ).firstMatch(text.trim());
    final wikiMatch = WikiLink.pattern.matchAsPrefix(text.trim());
    final wiki = wikiMatch != null && wikiMatch.end == text.trim().length
        ? WikiLink.fromMatch(wikiMatch)
        : null;
    if (legacy != null || wiki != null) {
      final snapshot = ref.watch(appProvider).snapshot;
      final note = legacy != null
          ? snapshot.note(legacy[2]!)
          : WikiNoteIndex(snapshot).resolve(wiki!.target);
      return Material(
        color: context.palette.raised,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => legacy != null
              ? showNotePreview(context, legacy[2]!)
              : _openWikiLink(context, ref, wiki!.target),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(
                  Icons.description_outlined,
                  color: context.accentColor,
                  size: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        note?.displayLabel ??
                            wiki?.label ??
                            wiki?.target ??
                            legacy![1]!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        note == null
                            ? tr("Заметка недоступна")
                            : note.content.replaceAll('\n', ' '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.palette.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.north_east_rounded,
                  size: 16,
                  color: context.palette.muted,
                ),
              ],
            ),
          ),
        ),
      );
    }
    var checkboxIndex = 0;
    final taskCount = text.contains(RegExp(r'\[[ xX]\]'))
        ? markdownTaskCount(text)
        : 0;
    return MarkdownBody(
      key: ValueKey(onChanged != null),
      data: text,
      // Match the editor: a single Enter stays a visible line break.
      softLineBreak: true,
      builders: {'pre': CodeBlockBuilder(selectable: selectable)},
      paddingBuilders: {'li': MarkdownTaskListBuilder()},
      checkboxBuilder: (checked) {
        // MarkdownBody can parse again after dependency changes. Each full
        // traversal must restart the same checkbox order.
        final index = taskCount == 0 ? 0 : checkboxIndex++ % taskCount;
        return SizedBox(
          width: 32,
          height: 32,
          child: Checkbox(
            value: checked,
            activeColor: context.accentColor,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            semanticLabel: tr("Подзадача"),
            onChanged: onChanged == null
                ? null
                : (value) {
                    if (!context.mounted) return;
                    // MarkdownBody caches its buttons when only a callback
                    // changes (e.g. editing a different live-preview block).
                    final preview = context.widget as MarkdownPreview;
                    final updated = setMarkdownTaskChecked(
                      preview.text,
                      index,
                      value!,
                    );
                    if (updated != preview.text) {
                      preview.onChanged?.call(updated);
                    }
                  },
          ),
        );
      },
      fitContent: false,
      inlineSyntaxes: [_WikiLinkSyntax(), MarkdownAutolinkSyntax()],
      selectable: selectable,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: TextStyle(height: 1.65, color: context.palette.text),
        listIndent: taskCount > 0 ? 36 : null,
        code: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: context.accentColor,
        ),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: context.accentColor, width: 2),
          ),
        ),
      ),
      onTapLink: (label, href, title) {
        if (href != null) _openMarkdownLink(context, ref, href);
      },
      imageBuilder: (uri, title, alt) {
        if (uri.scheme == 'attachment') {
          return FutureBuilder<String?>(
            future: ref.read(appProvider).attachmentPath(uri.path),
            builder: (context, snapshot) {
              if (snapshot.data == null) {
                return Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: context.palette.raised,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(alt ?? tr("Изображение ожидает синхронизации")),
                );
              }
              return GestureDetector(
                onTap: () => openAttachment(context, uri.path),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(
                    File(snapshot.data!),
                    fit: BoxFit.contain,
                    errorBuilder: (_, error, stack) =>
                        Text(tr("Не удалось прочитать изображение")),
                  ),
                ),
              );
            },
          );
        }
        return Text(
          tr("Внешнее изображение: откройте ссылку или добавьте файл"),
        );
      },
    );
  }
}

class _WikiLinkSyntax extends md.InlineSyntax {
  _WikiLinkSyntax() : super(WikiLink.pattern.pattern, startCharacter: 0x5b);
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final link = WikiLink.fromMatch(match);
    final node = md.Element.text('a', link.label ?? link.target);
    node.attributes['href'] = Uri(scheme: 'wiki', path: link.target).toString();
    parser.addNode(node);
    return true;
  }
}

Future<void> _openWikiLink(
  BuildContext context,
  WidgetRef ref,
  String target,
) async {
  final matches = WikiNoteIndex(ref.read(appProvider).snapshot).matches(target);
  final note = matches.length > 1
      ? await pickNote(context, onlyIds: matches.map((n) => n.id).toSet())
      : matches.singleOrNull;
  if (!context.mounted || (matches.length > 1 && note == null)) return;
  if (note != null) {
    await showNotePreview(context, note.id);
  } else {
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(tr("Заметка не найдена")),
        content: Text(
          tr(
            "«{0}» удалена, переименована на другом устройстве или ещё не синхронизирована.",
            [target],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(tr("Закрыть")),
          ),
        ],
      ),
    );
  }
}

/// One native text input keeps source offsets, selection and newlines intact.
/// Closed Markdown renders inline; source markers return around the caret.
class LiveMarkdownEditor extends ConsumerStatefulWidget {
  const LiveMarkdownEditor({
    super.key,
    required this.value,
    required this.onChanged,
    this.readOnly = false,
    this.placeholder = 'Начните писать…',
    this.toolbar = true,
    this.toolbarLabel = 'Markdown',
    this.continuousInput = false,
    this.onEditingChanged,
    this.toolbarLeading,
    this.toolbarTrailing,
    this.noteId,
  });
  final String value, placeholder, toolbarLabel;
  final ValueChanged<String> onChanged;
  final bool readOnly, toolbar, continuousInput;
  final ValueChanged<bool>? onEditingChanged;
  final Widget? toolbarLeading, toolbarTrailing;
  final String? noteId;
  @override
  ConsumerState<LiveMarkdownEditor> createState() => LiveMarkdownEditorState();
}

class LiveMarkdownEditorState extends ConsumerState<LiveMarkdownEditor>
    with UndoManagerClient {
  late List<String> _blocks;
  bool _isEditing = false;
  bool _pasting = false;
  TextSelection? _rememberedSelection;
  final _controller = MarkdownLiveController();
  final _inputKey = GlobalKey();
  final _focus = FocusNode();
  String _last = '';

  final _document = ValueNotifier<TextEditingValue>(TextEditingValue.empty);
  final _history = UndoHistoryController();
  Key _historyKey = UniqueKey();

  @override
  bool get canUndo => _history.value.canUndo && !_pasting && !widget.readOnly;
  @override
  bool get canRedo => _history.value.canRedo && !_pasting && !widget.readOnly;
  @override
  void undo() {
    if (!_pasting && !widget.readOnly) _history.undo();
  }

  @override
  void redo() {
    if (!_pasting && !widget.readOnly) _history.redo();
  }

  @override
  void handlePlatformUndo(UndoDirection direction) {
    switch (direction) {
      case UndoDirection.undo:
        undo();
      case UndoDirection.redo:
        redo();
    }
  }

  void _updatePlatformUndo() {
    if (_focus.hasFocus &&
        UndoManager.client == this &&
        defaultTargetPlatform == TargetPlatform.iOS) {
      UndoManager.setUndoState(canUndo: canUndo, canRedo: canRedo);
    }
  }

  void _publishEdit() {
    _document.value = TextEditingValue(text: _last, selection: _selection);
    widget.onChanged(normalizeMarkdownEnding(_last));
  }

  void _restoreDocument(TextEditingValue value) {
    setState(() {
      _document.value = value;
      _last = value.text;
      _isEditing = true;
      _controller.value = value;
    });
    widget.onChanged(normalizeMarkdownEnding(_last));
    _focus.requestFocus();
  }

  void finishEditing() {
    _focus.unfocus(
      disposition: widget.continuousInput
          ? UnfocusDisposition.scope
          : UnfocusDisposition.previouslyFocusedChild,
    );
    _finish();
  }

  void focusEditor() {
    if (widget.readOnly || _pasting) return;
    if (!_isEditing) {
      _edit(0);
    } else {
      _focus.requestFocus();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Scrollable.ensureVisible(
          _focus.context ?? context,
          duration: const Duration(milliseconds: 180),
          alignment: .35,
        );
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _controller.revealSource = !widget.continuousInput;
    _load(widget.value);
    _document.value = TextEditingValue(
      text: _last,
      selection: TextSelection.collapsed(offset: _last.length),
    );
    _focus.addListener(_focusChanged);
    _history.addListener(_updatePlatformUndo);
  }

  void _load(String value) {
    _last = value;
    _blocks = _split(value);
    _controller.value = TextEditingValue(text: value);
  }

  static List<String> _split(String value) {
    final parts = <String>[];
    MarkdownFence? fence;
    var start = 0, offset = 0;
    for (final line in value.split('\n')) {
      if (fence != null) {
        if (fence.closes(line)) {
          fence = null;
          if (offset + line.length < value.length) {
            parts.add(value.substring(start, offset + line.length + 1));
            start = offset + line.length + 1;
          }
        }
      } else {
        fence = MarkdownFence.open(line);
        if (fence != null && offset > start) {
          parts.add(value.substring(start, offset));
          start = offset;
        }
        // Consume an actual blank-line separator, never the single final
        // newline needed to keep typing on the next line.
        if (fence == null &&
            line.isEmpty &&
            offset > start &&
            offset < value.length) {
          parts.add(value.substring(start, offset + 1));
          start = offset + 1;
        }
      }
      offset += line.length + 1;
    }
    parts.add(value.substring(start));
    final listStart = RegExp(r'^\n* {0,3}(?:[-+*]|[0-9]{1,9}[.)])[ \t]+');
    final indented = RegExp(r'^\n*(?: {2,}|\t)');
    final blocks = <String>[];
    for (final part in parts) {
      if (blocks.isNotEmpty &&
          listStart.hasMatch(blocks.last) &&
          (listStart.hasMatch(part) || indented.hasMatch(part))) {
        blocks[blocks.length - 1] = '${blocks.last}$part';
      } else {
        blocks.add(part);
      }
    }
    return blocks;
  }

  @override
  void didUpdateWidget(covariant LiveMarkdownEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != _last && !_focus.hasFocus) {
      _load(widget.value);
      _historyKey = UniqueKey();
      _document.value = TextEditingValue(
        text: _last,
        selection: TextSelection.collapsed(offset: _last.length),
      );
      _isEditing = false;
      _rememberedSelection = null;
    }
    if (widget.readOnly && !oldWidget.readOnly) {
      _focus.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
      _finish(notify: false);
    }
  }

  void _focusChanged() {
    _controller.revealSource = !widget.continuousInput || _focus.hasFocus;
    if (_focus.hasFocus) {
      if (widget.continuousInput && !_isEditing) {
        setState(() => _isEditing = true);
        widget.onEditingChanged?.call(true);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_focus.hasFocus) return;
        // Native iOS undo must restore the document, not the active paragraph.
        UndoManager.client = this;
        _updatePlatformUndo();
      });
    }
    if (!_focus.hasFocus && mounted) {
      if (UndoManager.client == this) UndoManager.client = null;
      _rememberedSelection = _selection;
      if (!_pasting) _finish();
    }
  }

  void _finish({bool notify = true}) {
    if (!_isEditing) return;
    setState(() {
      _load(normalizeMarkdownEnding(_last));
      _isEditing = false;
    });
    if (notify) widget.onEditingChanged?.call(false);
  }

  void _edit(int index) {
    final wasEditing = _isEditing;
    final offset =
        _blocks.take(index).fold<int>(0, (n, part) => n + part.length) +
        _blocks[index].trimRight().length;
    setState(() {
      _isEditing = true;
      _controller.value = TextEditingValue(
        text: _last,
        selection: TextSelection.collapsed(
          offset: offset.clamp(0, _last.length),
        ),
      );
    });
    _focus.requestFocus();
    if (!wasEditing) widget.onEditingChanged?.call(true);
  }

  void _editEnd() {
    // Clicking the empty area only moves the caret; it must not insert text.
    if (!_isEditing) _edit(_blocks.length - 1);
    _controller.selection = TextSelection.collapsed(offset: _last.length);
    _focus.requestFocus();
  }

  void _changed(String value) {
    final wasEmpty = _last.isEmpty;
    _last = value;
    if (wasEmpty != value.isEmpty) setState(() {});
    _publishEdit();
  }

  TextSelection get _selection {
    final selection = _controller.selection;
    if (_isEditing && selection.isValid) {
      return selection;
    }
    return _rememberedSelection ??
        TextSelection.collapsed(offset: _last.length);
  }

  Future<void> _insertFrom(Future<ClipboardPaste?> Function() read) async {
    if (_pasting ||
        widget.readOnly ||
        (widget.continuousInput && !_isEditing)) {
      return;
    }
    final before = _last;
    final selection = _selection;
    setState(() => _pasting = true);
    try {
      await guard(context, () async {
        final content = await read();
        if (!mounted ||
            widget.readOnly ||
            content == null ||
            (widget.continuousInput && !_isEditing)) {
          return;
        }
        _insert(content, _last == before ? selection : _selection);
      });
    } finally {
      if (mounted) setState(() => _pasting = false);
    }
  }

  Future<void> _paste() => _insertFrom(() async {
    final content = await ref.read(clipboardProvider).read();
    if (content == null) {
      throw StateError(tr("В буфере обмена нет текста или файлов"));
    }
    return content;
  });

  void _insert(ClipboardPaste content, TextSelection selection) {
    final start = selection.start.clamp(0, _last.length);
    final end = selection.end.clamp(start, _last.length);
    final prefix = _last.substring(0, start), suffix = _last.substring(end);
    var inserted = content.text;
    if (content.hasAttachments) {
      if (prefix.isNotEmpty && !prefix.endsWith('\n\n')) {
        inserted = '\n\n$inserted';
      }
      if (!suffix.startsWith('\n\n')) inserted = '$inserted\n\n';
    }
    final next = '$prefix$inserted$suffix';
    setState(() {
      _last = next;
      _rememberedSelection = null;
      _isEditing = true;
      _controller.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(
          offset: prefix.length + inserted.length,
        ),
      );
    });
    _publishEdit();
    _focus.requestFocus();
  }

  void _selectAll() {
    if (widget.readOnly || _pasting) return;
    final wasEditing = _isEditing;
    setState(() {
      // Native selection spans the complete source document.
      _isEditing = true;
      _rememberedSelection = null;
      _controller.value = TextEditingValue(
        text: _last,
        selection: TextSelection(baseOffset: 0, extentOffset: _last.length),
      );
    });
    _focus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.readOnly) _focus.requestFocus();
    });
    if (!wasEditing) widget.onEditingChanged?.call(true);
  }

  void _selectLink(TextSelection selection) {
    if (widget.readOnly || _pasting) return;
    _controller.selection = selection;
    _focus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_focus.hasFocus) return;
      final input = _focus.context
          ?.findAncestorStateOfType<EditableTextState>();
      input?.userUpdateTextEditingValue(
        _controller.value,
        SelectionChangedCause.longPress,
      );
      input?.showToolbar();
    });
  }

  Widget _contextMenu(BuildContext context, EditableTextState state) =>
      TextFieldTapRegion(
        groupId: _focus,
        child: AdaptiveTextSelectionToolbar.buttonItems(
          anchors: state.contextMenuAnchors,
          buttonItems: [
            for (final item in state.contextMenuButtonItems)
              if (item.type == ContextMenuButtonType.selectAll)
                ContextMenuButtonItem(
                  type: ContextMenuButtonType.selectAll,
                  onPressed: () {
                    state.hideToolbar();
                    _selectAll();
                  },
                )
              else if (item.type != ContextMenuButtonType.paste)
                item,
            ContextMenuButtonItem(
              type: ContextMenuButtonType.paste,
              onPressed: () {
                state.hideToolbar();
                _paste();
              },
            ),
          ],
        ),
      );

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _focus.dispose();

    _controller.dispose();
    _document.dispose();
    _history.removeListener(_updatePlatformUndo);
    _history.dispose();
    if (UndoManager.client == this) UndoManager.client = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UndoHistory<TextEditingValue>(
    key: _historyKey,
    controller: _history,
    value: _document,
    focusNode: _focus,
    shouldChangeUndoStack: (before, after) => before?.text != after.text,
    onTriggered: _restoreDocument,
    child: Actions(
      actions: {
        UndoTextIntent: CallbackAction<UndoTextIntent>(
          onInvoke: (_) {
            undo();
            return null;
          },
        ),
        RedoTextIntent: CallbackAction<RedoTextIntent>(
          onInvoke: (_) {
            redo();
            return null;
          },
        ),
        if (!widget.readOnly)
          PasteTextIntent: CallbackAction<PasteTextIntent>(
            onInvoke: (_) => _paste(),
          ),
      },
      child: TextFieldTapRegion(
        groupId: _focus,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if ((widget.toolbar && widget.toolbarLabel.isNotEmpty) ||
                widget.toolbarLeading != null ||
                widget.toolbarTrailing != null)
              Row(
                children: [
                  if (widget.toolbarLeading != null)
                    widget.toolbarLeading!
                  else if (widget.toolbarLabel.isNotEmpty)
                    Text(
                      widget.toolbarLabel,
                      style: TextStyle(
                        fontSize: 12,
                        color: context.palette.muted,
                      ),
                    ),
                  const Spacer(),
                  if (widget.toolbarTrailing != null) widget.toolbarTrailing!,
                ],
              ),
            if (widget.readOnly)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: MarkdownPreview(
                  text: _last.isEmpty ? tr("Пока пусто") : _last,
                ),
              )
            else if (_isEditing || widget.continuousInput)
              LayoutBuilder(
                builder: (context, bounds) {
                  _controller.previewWidth = (bounds.maxWidth - 10).clamp(
                    1,
                    double.infinity,
                  );
                  _controller.selectLink = _selectLink;
                  _controller.openLink = widget.continuousInput
                      ? (href) => _openMarkdownLink(context, ref, href)
                      : null;
                  _controller.preview = (source) =>
                      MarkdownPreview(text: source, selectable: false);
                  _controller.toggleTask = _pasting
                      ? null
                      : (offset, checked) {
                          if (widget.readOnly || offset >= _last.length) return;
                          final next = _last.replaceRange(
                            offset,
                            offset + 1,
                            checked ? 'x' : ' ',
                          );
                          _controller.value = _controller.value.copyWith(
                            text: next,
                          );
                          _changed(next);
                        };
                  return _autocomplete(
                    TextField(
                      key: _inputKey,
                      controller: _controller,
                      focusNode: _focus,
                      groupId: _focus,
                      onTapOutside: widget.continuousInput
                          ? (_) => finishEditing()
                          : null,
                      readOnly: _pasting,
                      contextMenuBuilder: _contextMenu,
                      inputFormatters: const [MarkdownTaskInputFormatter()],
                      maxLines: null,
                      minLines: 1,
                      style: const TextStyle(fontSize: 14, height: 1.65),
                      strutStyle: const StrutStyle(
                        fontSize: 14,
                        height: 1.65,
                        forceStrutHeight: false,
                      ),
                      decoration: InputDecoration(
                        hintText: _last.isEmpty ? widget.placeholder : '',
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 9,
                          horizontal: 3,
                        ),
                      ),
                      onChanged: _changed,
                    ),
                  );
                },
              )
            else
              ...List.generate(
                _blocks.length,
                (index) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _edit(index),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.text,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 9,
                        horizontal: 3,
                      ),
                      child: _blocks[index].isEmpty
                          ? Text(
                              _last.isEmpty && index == 0
                                  ? widget.placeholder
                                  : '',
                              style: TextStyle(
                                color: context.palette.muted,
                                height: 1.65,
                              ),
                            )
                          : _previewBlock(index),
                    ),
                  ),
                ),
              ),
            if (!widget.readOnly)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _editEnd,
                child: const SizedBox(height: 40),
              ),
          ],
        ),
      ),
    ),
  );

  Widget _previewBlock(int index) {
    final block = _blocks[index], document = _last;
    final start = _blocks
        .take(index)
        .fold<int>(0, (n, part) => n + part.length);
    return MarkdownPreview(
      text: block,
      selectable: false,
      onChanged: _pasting
          ? null
          : (value) {
              if (widget.readOnly || _last != document) return;
              setState(() {
                _last = document.replaceRange(
                  start,
                  start + block.length,
                  value,
                );
                _load(_last);
              });
              _publishEdit();
            },
    );
  }

  Widget _autocomplete(Widget child) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyA, meta: true): _selectAll,
      const SingleActivator(LogicalKeyboardKey.keyA, control: true): _selectAll,
    },
    child: WikiAutocomplete(
      controller: _controller,
      focusNode: _focus,
      onChanged: _changed,
      readOnly: _pasting || widget.readOnly,
      noteId: widget.noteId,
      child: child,
    ),
  );
}

Future<Note?> pickNote(
  BuildContext context, {
  Set<String>? onlyIds,
  String? excludeId,
}) => showDialog<Note>(
  context: context,
  builder: (_) => _NotePicker(onlyIds: onlyIds, excludeId: excludeId),
);

class _NotePicker extends ConsumerStatefulWidget {
  const _NotePicker({this.onlyIds, this.excludeId});
  final Set<String>? onlyIds;
  final String? excludeId;
  @override
  ConsumerState<_NotePicker> createState() => _NotePickerState();
}

class _NotePickerState extends ConsumerState<_NotePicker> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final index = WikiNoteIndex(ref.watch(appProvider).snapshot);
    final notes = index.search(
      query,
      limit: 100,
      onlyIds: widget.onlyIds,
      excludeId: widget.excludeId,
    );
    return AlertDialog(
      title: Text(tr("Ссылка на заметку")),
      content: SizedBox(
        width: 480,
        height: 380,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: InputDecoration(
                hintText: tr("Найти заметку"),
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: (v) => setState(() => query = v),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: notes.isEmpty
                  ? Center(child: Text(tr("Заметок не найдено")))
                  : ListView.builder(
                      itemCount: notes.length,
                      itemBuilder: (_, i) {
                        final note = notes[i];
                        return ListTile(
                          leading: const Icon(Icons.description_outlined),
                          title: Text(
                            note.displayLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${index.folderLabel(note)} · ${note.content.replaceAll('\n', ' ')}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => Navigator.pop(context, note),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr("Отмена")),
        ),
      ],
    );
  }
}

Future<void> showNotePreview(BuildContext context, String id) =>
    showDialog<void>(
      context: context,
      builder: (_) => Consumer(
        builder: (context, ref, _) {
          final note = ref.watch(appProvider).snapshot.note(id);
          return AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.description_outlined, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    note?.displayLabel ?? tr("Заметка недоступна"),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 560,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .55,
                ),
                child: SingleChildScrollView(
                  child: note == null
                      ? Text(tr("Заметка удалена или ещё не синхронизирована."))
                      : MarkdownPreview(
                          text: note.content.isEmpty
                              ? tr("Пока пусто")
                              : note.content,
                        ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(tr("Закрыть")),
              ),
              if (note != null)
                FilledButton(
                  onPressed: () {
                    Navigator.pop(context);
                    ref.read(openNoteProvider.notifier).state = id;
                  },
                  child: Text(tr("Открыть заметку")),
                ),
            ],
          );
        },
      ),
    );
