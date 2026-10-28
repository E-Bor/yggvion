import '../l10n/strings.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'theme.dart';

class CodeBlockBuilder extends MarkdownElementBuilder {
  CodeBlockBuilder({required this.selectable});
  final bool selectable;

  @override
  bool isBlockElement() => true;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final code = element.children?.whereType<md.Element>().firstOrNull;
    final language = code?.attributes['class']
        ?.replaceFirst('language-', '')
        .split(' ')
        .first;
    return MarkdownCodeBlock(
      code: element.textContent,
      language: language,
      selectable: selectable,
    );
  }
}

class MarkdownCodeBlock extends StatefulWidget {
  const MarkdownCodeBlock({
    super.key,
    required this.code,
    this.language,
    this.selectable = true,
  });
  final String code;
  final String? language;
  final bool selectable;

  @override
  State<MarkdownCodeBlock> createState() => _MarkdownCodeBlockState();
}

class _MarkdownCodeBlockState extends State<MarkdownCodeBlock> {
  final scroll = ScrollController();
  Timer? feedback;
  bool hovered = false, focused = false, copied = false;

  @override
  void dispose() {
    feedback?.cancel();
    scroll.dispose();
    super.dispose();
  }

  Future<void> copy() async {
    await guard(context, () async {
      await Clipboard.setData(ClipboardData(text: widget.code));
      if (!mounted) return;
      setState(() => copied = true);
      feedback?.cancel();
      feedback = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => copied = false);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final touch =
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android;
    final showCopy = touch || hovered || focused || copied;
    final style = TextStyle(
      fontFamily: 'monospace',
      fontSize: 13,
      height: 1.55,
      color: context.palette.text,
    );
    // Only code scrolls. The action belongs to the viewport, even for lines
    // thousands of characters wide, and remains reachable by touch/keyboard.
    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: context.palette.raised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.palette.border),
      ),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 64, 4),
                child: Text(
                  widget.language?.isNotEmpty == true
                      ? widget.language!
                      : tr("Код"),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: context.palette.muted),
                ),
              ),
              Scrollbar(
                controller: scroll,
                child: SingleChildScrollView(
                  controller: scroll,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: widget.selectable
                      ? SelectableText(widget.code, style: style)
                      : Text(widget.code, style: style),
                ),
              ),
            ],
          ),
          Positioned(
            top: 0,
            right: 0,
            child: MouseRegion(
              onEnter: (_) => setState(() => hovered = true),
              onExit: (_) => setState(() => hovered = false),
              child: SizedBox(
                width: 60,
                height: 44,
                child: Focus(
                  onFocusChange: (value) => setState(() => focused = value),
                  child: IgnorePointer(
                    ignoring: !showCopy,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 120),
                      opacity: showCopy ? 1 : 0,
                      child: IconButton(
                        tooltip: copied
                            ? tr("Скопировано")
                            : tr("Скопировать код"),
                        onPressed: copy,
                        icon: Icon(
                          copied ? Icons.check_rounded : Icons.copy_rounded,
                          size: 18,
                          color: copied
                              ? context.accentColor
                              : context.palette.muted,
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
}
