import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;
import '../domain/markdown_blocks.dart';
import 'theme.dart';

/// A single source document and native selection/IME connection. Presentation
/// never rewrites the editing value or splits it into independently edited blocks.
class MarkdownLiveController extends TextEditingController {
  Widget Function(String source)? preview;
  void Function(int offset, bool checked)? toggleTask;
  double previewWidth = 300;
  ValueChanged<String>? openLink;
  bool _revealSource = true;
  ValueChanged<TextSelection>? selectLink;

  set revealSource(bool value) {
    if (_revealSource == value) return;
    _revealSource = value;
    notifyListeners();
  }

  static final _heading = RegExp(r'^ {0,3}(#{1,6})[ \t]+');
  static final _task = RegExp(r'^([ \t]*[-+*][ \t]+)\[([ xX])\][ \t]+');
  static final _quote = RegExp(r'^ {0,3}>[ \t]?');
  static final _embed = RegExp(
    r'^\s*(?:!\[[^\]]*\]\([^\n]+\)|\[\[[^\]\n]+\]\]|\[[^\]]*\]\(note:[a-zA-Z0-9_-]+\))\s*$',
  );
  static final _autolinkSyntax = md.AutolinkExtensionSyntax();
  static final _autolinkDocument = md.Document(
    encodeHtml: false,
    extensionSet: md.ExtensionSet.gitHubFlavored,
  );
  static final _autolinkBoundary = RegExp(r'[\s*_~(>]');
  static final _inline = RegExp(
    r'(`+)([^`\n]+)\1|\*\*(?=\S)(.+?\S|\S)\*\*|__(?=\S)(.+?\S|\S)__|~~(?=\S)(.+?\S|\S)~~|\*(?=\S)([^*\n]*\S)\*|_(?=\S)([^_\n]*\S)_|\[\[([^\]\n]+)\]\]|\[([^\]\n]+)\]\(([^)\n]+)\)'
    r'|(<https?://[^<>\s]+>)'
    '|(${_autolinkSyntax.pattern.pattern})',
    caseSensitive: false,
  );
  String? _parsedText;
  List<_LiveLine> _lines = [];

  bool _editing(int start, int end) {
    if (!_revealSource) return false;
    final range = value.composing;
    if (range.isValid &&
        !range.isCollapsed &&
        range.start < end &&
        range.end > start) {
      return true;
    }
    final selected = selection;
    if (!selected.isValid) return false;
    return selected.isCollapsed
        ? selected.extentOffset >= start && selected.extentOffset <= end
        : selected.start < end && selected.end > start;
  }

  TextSpan _hidden(String source, {bool lines = false}) => TextSpan(
    // WidgetSpan occupies one UTF-16 position. The remaining invisible source
    // positions keep all native selection offsets aligned with the document.
    text: lines
        ? source.replaceAll('\n', '\u200b').replaceAll('\r', '\u200b')
        : source,
    style: const TextStyle(
      fontSize: 0,
      height: 1,
      letterSpacing: 0,
      wordSpacing: 0,
      color: Colors.transparent,
    ),
  );

  void _parse() {
    if (_parsedText == text) return;
    _parsedText = text;
    _lines = [];
    var offset = 0;
    for (final line in text.split('\n')) {
      _lines.add(_LiveLine(offset, line));
      offset += line.length + 1;
    }
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    _parse();
    final base = style ?? const TextStyle(fontSize: 14, height: 1.65);
    final children = <InlineSpan>[];
    final code = TextStyle(
      fontFamily: 'monospace',
      color: context.accentColor,
      backgroundColor: context.palette.raised,
    );
    for (var i = 0; i < _lines.length; i++) {
      final line = _lines[i];
      final fence = MarkdownFence.open(line.text);
      if (fence != null) {
        var close = i + 1;
        while (close < _lines.length && !fence.closes(_lines[close].text)) {
          close++;
        }
        final closed = close < _lines.length;
        final last = closed ? _lines[close] : _lines.last;
        final end = last.start + last.text.length;
        if (closed && !_editing(line.start, end) && preview != null) {
          children.addAll(_preview(text.substring(line.start, end)));
        } else {
          children.add(
            TextSpan(text: text.substring(line.start, end), style: code),
          );
        }
        i = closed ? close : _lines.length - 1;
      } else if (_embed.hasMatch(line.text) &&
          !_editing(line.start, line.end) &&
          preview != null) {
        children.addAll(_preview(line.text));
      } else {
        final heading = _heading.firstMatch(line.text);
        final task = _task.firstMatch(line.text);
        final quote = _quote.firstMatch(line.text);
        var start = 0;
        TextStyle? lineStyle;
        if (heading != null) {
          final level = heading[1]!.length;
          lineStyle = TextStyle(
            fontSize: [26.0, 23.0, 20.0, 18.0, 16.0, 14.0][level - 1],
            fontWeight: FontWeight.w600,
          );
          start = heading.end;
          children.add(
            _editing(line.start, line.end)
                ? TextSpan(
                    text: heading[0],
                    style: TextStyle(color: context.palette.muted),
                  )
                : _hidden(heading[0]!),
          );
        } else if (task != null &&
            !_editing(line.start, line.start + task.end)) {
          start = task.end;
          final checked = task[2]!.toLowerCase() == 'x';
          if (checked) {
            lineStyle = TextStyle(
              decoration: TextDecoration.lineThrough,
              color: context.palette.muted,
            );
          }
          children.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: SizedBox(
                width: 26,
                height: 24,
                child: Checkbox(
                  value: checked,
                  activeColor: context.accentColor,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  semanticLabel: 'Подзадача',
                  onChanged: toggleTask == null
                      ? null
                      : (checked) => toggleTask!(
                          line.start + task[1]!.length + 1,
                          checked!,
                        ),
                ),
              ),
            ),
          );
          children.add(_hidden(line.text.substring(1, start)));
        } else if (quote != null) {
          start = quote.end;
          lineStyle = TextStyle(
            color: context.palette.muted,
            fontStyle: FontStyle.italic,
          );
          children.add(
            TextSpan(
              text: quote[0],
              style: TextStyle(color: context.accentColor),
            ),
          );
        }
        children.add(
          TextSpan(
            style: lineStyle,
            children: _inlines(
              context,
              line.text.substring(start),
              line.start + start,
              0,
              base.merge(lineStyle),
            ),
          ),
        );
      }
      if (i < _lines.length - 1) children.add(const TextSpan(text: '\n'));
    }
    final result = TextSpan(style: base, children: children);
    if (!withComposing ||
        !value.isComposingRangeValid ||
        value.composing.isCollapsed) {
      return result;
    }
    // Only the composing range changes appearance. Replacing the entire rich
    // document with plain text here would make headings and embeds jump every
    // time a phone keyboard starts an IME composition.
    var offset = 0;
    final range = value.composing;
    InlineSpan underline(InlineSpan span, TextStyle inherited) {
      if (span is WidgetSpan) {
        offset++;
        return span;
      }
      if (span is! TextSpan) return span;
      final effective = inherited.merge(span.style);
      final source = span.text ?? '';
      final start = (range.start - offset).clamp(0, source.length);
      final end = (range.end - offset).clamp(start, source.length);
      offset += source.length;
      final parts = <InlineSpan>[
        if (start > 0) TextSpan(text: source.substring(0, start)),
        if (end > start)
          TextSpan(
            text: source.substring(start, end),
            style: TextStyle(
              decoration: TextDecoration.combine([
                if (effective.decoration != null) effective.decoration!,
                TextDecoration.underline,
              ]),
            ),
          ),
        if (end < source.length) TextSpan(text: source.substring(end)),
        for (final child in span.children ?? <InlineSpan>[])
          underline(child, effective),
      ];
      return TextSpan(style: span.style, children: parts);
    }

    return underline(result, base) as TextSpan;
  }

  List<InlineSpan> _preview(String source) => [
    WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: SizedBox(width: previewWidth, child: preview!(source)),
    ),
    _hidden(source.substring(1), lines: true),
  ];

  List<InlineSpan> _inlines(
    BuildContext context,
    String source,
    int offset, [
    int depth = 0,
    TextStyle? inheritedStyle,
    bool detectAutolinks = true,
  ]) {
    if (depth > 12) return [TextSpan(text: source)];
    final result = <InlineSpan>[];
    var cursor = 0;
    for (final match in _inline.allMatches(source)) {
      // Escaped markers are literal; code spans are consumed as a unit, so no
      // Markdown formatting is interpreted inside them.
      var slashes = 0;
      for (var i = match.start - 1; i >= 0 && source[i] == '\\'; i--) {
        slashes++;
      }
      if (slashes.isOdd) continue;
      if (match.start > cursor) {
        result.add(TextSpan(text: source.substring(cursor, match.start)));
      }
      var raw = match[0]!;
      final editing = _editing(offset + match.start, offset + match.end);
      var prefix = 0, suffix = 0;
      TextStyle? format;
      final automatic = match[11] != null || match[12] != null;
      String? href;
      var trailing = '';
      if (automatic) {
        final invalidBoundary =
            match[11] == null &&
            match[14] == null &&
            match.start > 0 &&
            !_autolinkBoundary.hasMatch(source[match.start - 1]);
        final node = detectAutolinks && !invalidBoundary
            ? _autolinkDocument.parseInline(raw).firstOrNull
            : null;
        if (node is! md.Element ||
            node.tag != 'a' ||
            !{
              'http',
              'https',
              'mailto',
            }.contains(Uri.tryParse(node.attributes['href'] ?? '')?.scheme)) {
          result.add(TextSpan(text: raw));
          cursor = match.end;
          continue;
        }
        href = node.attributes['href']!;
        prefix = suffix = match[11] != null ? 1 : 0;
        final length = prefix + node.textContent.length + suffix;
        trailing = raw.substring(length);
        raw = raw.substring(0, length);
        format = TextStyle(
          color: context.accentColor,
          decoration: TextDecoration.underline,
        );
      } else if (match[1] != null) {
        prefix = suffix = match[1]!.length;
        format = TextStyle(
          fontFamily: 'monospace',
          color: context.accentColor,
          backgroundColor: context.palette.raised,
        );
      } else if (match[3] != null || match[4] != null) {
        prefix = suffix = 2;
        format = const TextStyle(fontWeight: FontWeight.w700);
      } else if (match[5] != null) {
        prefix = suffix = 2;
        format = const TextStyle(decoration: TextDecoration.lineThrough);
      } else if (match[6] != null || match[7] != null) {
        prefix = suffix = 1;
        format = const TextStyle(fontStyle: FontStyle.italic);
      } else if (match[8] != null) {
        prefix = suffix = 2;
        final alias = raw.indexOf('|', 2);
        if (alias >= 0) prefix = alias + 1;
        format = TextStyle(color: context.accentColor);
      } else {
        prefix = 1;
        suffix = raw.length - match[9]!.length - 1;
        format = TextStyle(
          color: context.accentColor,
          decoration: TextDecoration.underline,
        );
      }
      href ??= match[8] != null
          ? 'wiki:${Uri.encodeComponent(match[8]!.split('|').first.trim())}'
          : match[10];
      final inner = raw.substring(prefix, raw.length - suffix);
      final destination = href;
      if (!editing && destination != null && openLink != null) {
        // EditableText cannot expose recognizers in an editable TextSpan.
        // Links use the same embedded-widget approach as task checkboxes.
        final labelStart = offset + match.start + prefix;
        result.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: previewWidth),
              child: Semantics(
                link: true,
                child: GestureDetector(
                  onTap: () => openLink?.call(destination),
                  onLongPress: selectLink == null
                      ? null
                      : () => selectLink!(
                          TextSelection(
                            baseOffset: labelStart,
                            extentOffset: labelStart + inner.length,
                          ),
                        ),
                  child: Text.rich(
                    TextSpan(
                      children: automatic
                          ? [TextSpan(text: inner)]
                          : _inlines(
                              context,
                              inner,
                              labelStart,
                              depth + 1,
                              inheritedStyle?.merge(format),
                              false,
                            ),
                    ),
                    style:
                        (inheritedStyle ??
                                const TextStyle(fontSize: 14, height: 1.65))
                            .merge(format),
                  ),
                ),
              ),
            ),
          ),
        );
        result.add(_hidden(raw.substring(1)));
        if (trailing.isNotEmpty) result.add(TextSpan(text: trailing));
        cursor = match.end;
        continue;
      }
      result.add(
        editing
            ? TextSpan(
                text: raw.substring(0, prefix),
                style: TextStyle(color: context.palette.muted),
              )
            : _hidden(raw.substring(0, prefix)),
      );
      result.add(
        TextSpan(
          style: format,
          children: match[1] != null || automatic
              ? [TextSpan(text: inner)]
              : _inlines(
                  context,
                  inner,
                  offset + match.start + prefix,
                  depth + 1,
                  inheritedStyle?.merge(format),
                  detectAutolinks && href == null,
                ),
        ),
      );
      result.add(
        editing
            ? TextSpan(
                text: raw.substring(raw.length - suffix),
                style: TextStyle(color: context.palette.muted),
              )
            : _hidden(raw.substring(raw.length - suffix)),
      );
      if (trailing.isNotEmpty) result.add(TextSpan(text: trailing));
      cursor = match.end;
    }
    if (cursor < source.length) {
      result.add(TextSpan(text: source.substring(cursor)));
    }
    return result;
  }
}

class _LiveLine {
  const _LiveLine(this.start, this.text);
  final int start;
  final String text;
  int get end => start + text.length;
}
