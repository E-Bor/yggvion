import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';
import '../data/clipboard.dart';
import 'providers.dart';
import 'theme.dart';

class MarkdownPreview extends ConsumerWidget {
  const MarkdownPreview({
    super.key,
    required this.text,
    this.selectable = true,
  });
  final String text;
  final bool selectable;
  @override
  Widget build(BuildContext context, WidgetRef ref) => MarkdownBody(
    data: text,
    selectable: selectable,
    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: const TextStyle(height: 1.65, color: Palette.text),
      code: const TextStyle(
        fontFamily: 'monospace',
        fontSize: 12,
        color: Palette.blue,
      ),
      blockquoteDecoration: const BoxDecoration(
        border: Border(left: BorderSide(color: Palette.blue, width: 2)),
      ),
    ),
    onTapLink: (label, href, title) {
      if (href == null) return;
      guard(context, () async {
        final uri = Uri.parse(href);
        if (uri.scheme == 'attachment') {
          final path = await ref.read(appProvider).attachmentPath(uri.path);
          if (path == null) {
            throw StateError('Вложение ещё не загружено на это устройство');
          }
          final result = await OpenFilex.open(path);
          if (result.type != ResultType.done) throw StateError(result.message);
        } else if (['https', 'http', 'mailto'].contains(uri.scheme)) {
          if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
            throw StateError('Не удалось открыть ссылку');
          }
        }
      });
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
                  color: Palette.raised,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(alt ?? 'Изображение ожидает синхронизации'),
              );
            }
            return ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(
                File(snapshot.data!),
                fit: BoxFit.contain,
                errorBuilder: (_, error, stack) =>
                    const Text('Не удалось прочитать изображение'),
              ),
            );
          },
        );
      }
      return const Text(
        'Внешнее изображение: откройте ссылку или добавьте файл',
      );
    },
  );
}

/// The focused Markdown block exposes source; other blocks render immediately.
/// Raw text remains authoritative, preserving Markdown that the renderer cannot display.
class LiveMarkdownEditor extends ConsumerStatefulWidget {
  const LiveMarkdownEditor({
    super.key,
    required this.value,
    required this.onChanged,
    this.readOnly = false,
    this.placeholder = 'Начните писать…',
    this.toolbar = true,
    this.toolbarLabel = 'Markdown',
  });
  final String value, placeholder, toolbarLabel;
  final ValueChanged<String> onChanged;
  final bool readOnly, toolbar;
  @override
  ConsumerState<LiveMarkdownEditor> createState() => LiveMarkdownEditorState();
}

class LiveMarkdownEditorState extends ConsumerState<LiveMarkdownEditor> {
  late List<String> _blocks;
  int? _active;
  bool _source = false;
  bool _pasting = false;
  TextSelection? _rememberedSelection;
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String _last = '';

  void focusEditor() {
    if (widget.readOnly || _pasting) return;
    if (!_source && _active == null) {
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
    _load(widget.value);
    _focus.addListener(_focusChanged);
  }

  void _load(String value) {
    _last = value;
    _blocks = _split(value);
  }

  static List<String> _split(String value) {
    final parts = <String>[];
    var buffer = <String>[];
    bool fenced = false;
    for (final line in value.split('\n')) {
      if (RegExp(r'^\s*(```|~~~)').hasMatch(line)) fenced = !fenced;
      if (line.isEmpty && !fenced && buffer.isNotEmpty) {
        parts.add(buffer.join('\n'));
        buffer = [];
      } else {
        buffer.add(line);
      }
    }
    if (buffer.isNotEmpty) parts.add(buffer.join('\n'));
    return parts.isEmpty ? [''] : parts;
  }

  @override
  void didUpdateWidget(covariant LiveMarkdownEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != _last && !_focus.hasFocus) {
      _load(widget.value);
      _active = null;
      _rememberedSelection = null;
    }
    if (widget.readOnly && !oldWidget.readOnly) {
      _finish();
    }
  }

  void _focusChanged() {
    if (!_focus.hasFocus && mounted) {
      _rememberedSelection = _selection;
      if (!_pasting) _finish();
    }
  }

  void _finish() {
    if (_active == null && !_source) return;
    setState(() {
      _load(_last);
      _active = null;
    });
  }

  void _edit(int index) {
    setState(() {
      _active = index;
      _controller.text = _blocks[index];
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    });
    _focus.requestFocus();
  }

  void _changed(String value) {
    if (_source) {
      _last = value;
    } else {
      _blocks[_active!] = value;
      _last = _blocks.join('\n\n');
    }
    widget.onChanged(_last);
  }

  TextSelection get _selection {
    final selection = _controller.selection;
    if ((_source || _active != null) && selection.isValid) {
      final offset = _source
          ? 0
          : _blocks
                .take(_active!)
                .fold<int>(0, (n, block) => n + block.length + 2);
      return TextSelection(
        baseOffset: offset + selection.baseOffset,
        extentOffset: offset + selection.extentOffset,
      );
    }
    return _rememberedSelection ??
        TextSelection.collapsed(offset: _last.length);
  }

  Future<void> _insertFrom(Future<ClipboardPaste?> Function() read) async {
    if (_pasting || widget.readOnly) return;
    final before = _last;
    final selection = _selection;
    setState(() => _pasting = true);
    try {
      await guard(context, () async {
        final content = await read();
        if (!mounted || widget.readOnly || content == null) return;
        _insert(content, _last == before ? selection : _selection);
      });
    } finally {
      if (mounted) setState(() => _pasting = false);
    }
  }

  Future<void> _paste() => _insertFrom(() async {
    final content = await ref.read(clipboardProvider).read();
    if (content == null) {
      throw StateError('В буфере обмена нет текста или файлов');
    }
    return content;
  });

  Future<void> _attach() => _insertFrom(() async {
    final repo = ref.read(appProvider);
    final selection = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (selection == null) return null;
    final links = <String>[];
    for (final file in selection.files) {
      if (file.path == null) {
        throw StateError('Не удалось прочитать файл ${file.name}');
      }
      links.add(await repo.attachFile(file.path!));
    }
    return ClipboardPaste(links.join('\n\n'), hasAttachments: true);
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
    var caret = prefix.length + inserted.length;
    setState(() {
      _load(next);
      _rememberedSelection = null;
      String edited;
      if (_source) {
        edited = next;
      } else {
        var index = 0;
        while (index < _blocks.length - 1 && caret > _blocks[index].length) {
          caret -= _blocks[index].length + 2;
          index++;
        }
        _active = index;
        edited = _blocks[index];
      }
      _controller.value = TextEditingValue(
        text: edited,
        selection: TextSelection.collapsed(
          offset: caret.clamp(0, edited.length),
        ),
      );
    });
    widget.onChanged(next);
    _focus.requestFocus();
  }

  Widget _contextMenu(BuildContext context, EditableTextState state) =>
      AdaptiveTextSelectionToolbar.buttonItems(
        anchors: state.contextMenuAnchors,
        buttonItems: [
          for (final item in state.contextMenuButtonItems)
            if (item.type != ContextMenuButtonType.paste) item,
          ContextMenuButtonItem(
            type: ContextMenuButtonType.paste,
            onPressed: () {
              state.hideToolbar();
              _paste();
            },
          ),
        ],
      );

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Actions(
    actions: {
      if (!widget.readOnly)
        PasteTextIntent: CallbackAction<PasteTextIntent>(
          onInvoke: (_) => _paste(),
        ),
    },
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.toolbar && !widget.readOnly)
          Row(
            children: [
              Text(
                widget.toolbarLabel,
                style: const TextStyle(fontSize: 12, color: Palette.muted),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Прикрепить изображение или файл',
                onPressed: _pasting ? null : _attach,
                icon: const Icon(Icons.attach_file_rounded, size: 19),
              ),
              IconButton(
                tooltip: 'Вставить из буфера обмена',
                onPressed: _pasting ? null : _paste,
                icon: _pasting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.content_paste_rounded, size: 18),
              ),
              IconButton(
                tooltip: _source ? 'Live Preview' : 'Исходный Markdown',
                onPressed: _pasting
                    ? null
                    : () {
                        setState(() {
                          _source = !_source;
                          _active = null;
                          _controller.text = _last;
                          _rememberedSelection = null;
                          _load(_last);
                        });
                      },
                icon: Icon(
                  _source ? Icons.visibility_outlined : Icons.code_rounded,
                  size: 19,
                ),
              ),
            ],
          ),
        if (widget.readOnly)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: MarkdownPreview(text: _last.isEmpty ? 'Пока пусто' : _last),
          )
        else if (_source)
          TextField(
            controller: _controller,
            focusNode: _focus,
            readOnly: _pasting,
            contextMenuBuilder: _contextMenu,
            maxLines: null,
            minLines: 5,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              height: 1.6,
            ),
            decoration: InputDecoration(
              hintText: widget.placeholder,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              fillColor: Colors.transparent,
            ),
            onChanged: _changed,
          )
        else
          ...List.generate(
            _blocks.length,
            (index) => _active == index
                ? TextField(
                    controller: _controller,
                    focusNode: _focus,
                    readOnly: _pasting,
                    contextMenuBuilder: _contextMenu,
                    maxLines: null,
                    minLines: 1,
                    style: const TextStyle(fontSize: 14, height: 1.65),
                    decoration: InputDecoration(
                      hintText: widget.placeholder,
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
                  )
                : GestureDetector(
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
                                widget.placeholder,
                                style: const TextStyle(
                                  color: Palette.muted,
                                  height: 1.65,
                                ),
                              )
                            : MarkdownPreview(
                                text: _blocks[index],
                                selectable: false,
                              ),
                      ),
                    ),
                  ),
          ),
        if (!widget.readOnly && !_source)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (_blocks.last.isNotEmpty) _blocks.add('');
              _edit(_blocks.length - 1);
            },
            child: const SizedBox(height: 40),
          ),
      ],
    ),
  );
}
