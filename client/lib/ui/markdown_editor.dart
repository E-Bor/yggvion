import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';
import 'providers.dart';
import 'theme.dart';

class MarkdownPreview extends ConsumerWidget {
  const MarkdownPreview({super.key, required this.text});
  final String text;
  @override
  Widget build(BuildContext context, WidgetRef ref) => MarkdownBody(
    data: text,
    selectable: true,
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
  });
  final String value, placeholder;
  final ValueChanged<String> onChanged;
  final bool readOnly, toolbar;
  @override
  ConsumerState<LiveMarkdownEditor> createState() => _LiveMarkdownEditorState();
}

class _LiveMarkdownEditorState extends ConsumerState<LiveMarkdownEditor> {
  late List<String> _blocks;
  int? _active;
  bool _source = false;
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String _last = '';
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
  void didUpdateWidget(covariant LiveMarkdownEditor old) {
    super.didUpdateWidget(old);
    if (widget.value != _last && !_focus.hasFocus) {
      _load(widget.value);
      _active = null;
    }
    if (widget.readOnly && !old.readOnly) {
      _finish();
    }
  }

  void _focusChanged() {
    if (!_focus.hasFocus && mounted) _finish();
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

  Future<void> _attach() async {
    final selection = await FilePicker.platform.pickFiles();
    if (selection == null || selection.files.single.path == null) return;
    if (!mounted) return;
    await guard(context, () async {
      final link = await ref
          .read(appProvider)
          .attachFile(selection.files.single.path!);
      final next = '$_last${_last.isEmpty ? '' : '\n\n'}$link';
      setState(() {
        _load(next);
        _active = null;
        if (_source) _controller.text = next;
      });
      widget.onChanged(next);
    });
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      if (widget.toolbar && !widget.readOnly)
        Row(
          children: [
            const Text(
              'MARKDOWN',
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 1.7,
                color: Palette.muted,
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Прикрепить изображение или файл',
              onPressed: _attach,
              icon: const Icon(Icons.attach_file_rounded, size: 19),
            ),
            IconButton(
              tooltip: _source ? 'Live Preview' : 'Исходный Markdown',
              onPressed: () {
                setState(() {
                  _source = !_source;
                  _active = null;
                  _controller.text = _last;
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
                          : MarkdownPreview(text: _blocks[index]),
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
  );
}
