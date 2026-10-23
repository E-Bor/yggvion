import 'dart:convert';

import 'package:markdown/markdown.dart' as md;

/// The input can be inside a paragraph in a loose (blank-line-separated) list.
md.Element? markdownTaskInput(md.Element item) {
  if (item.tag != 'li' || item.children?.isNotEmpty != true) return null;
  var first = item.children!.first;
  if (first is md.Element && first.tag == 'p') {
    if (first.children?.isNotEmpty != true) return null;
    first = first.children!.first;
  }
  return first is md.Element && first.attributes['type'] == 'checkbox'
      ? first
      : null;
}

/// Checkbox order matches flutter_markdown's list-item builder: children first.
List<bool> _checkboxes(String text) {
  final result = <bool>[];
  void visit(md.Node node) {
    if (node is! md.Element) return;
    for (final child in node.children ?? <md.Node>[]) {
      visit(child);
    }
    final input = markdownTaskInput(node);
    if (input != null) result.add(input.attributes.containsKey('checked'));
  }

  final document = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored);
  final lines = const LineSplitter().convert(text).map(md.Line.new).toList();
  for (final node in md.BlockParser(lines, document).parseLines()) {
    visit(node);
  }
  return result;
}

int markdownTaskCount(String text) => _checkboxes(text).length;

final _taskMarker = RegExp(
  r'^[ \t]*(?:>[ \t]*)*(?:[-+*]|[0-9]{1,9}[.)])[ \t]+\[([ xX])\](?=[ \t])',
  multiLine: true,
);

String _flipMarkers(String text, Iterable<int> offsets) {
  final result = StringBuffer();
  var start = 0;
  for (final offset in offsets) {
    result
      ..write(text.substring(start, offset))
      ..write(text[offset] == ' ' ? 'x' : ' ');
    start = offset + 1;
  }
  return (result..write(text.substring(start))).toString();
}

/// Only a real parsed task may change. A regexp alone also matches code fences,
/// indented code and HTML comments, and nested lists render out of source order.
/// The parser has no source offsets, so locate the clicked marker by checking
/// which half of the candidates changes that checkbox. This runs only on a tap,
/// takes log2(N) parses, and never changes whitespace or other Markdown bytes.
String setMarkdownTaskChecked(String text, int index, bool checked) {
  final original = _checkboxes(text);
  if (index < 0 || index >= original.length || original[index] == checked) {
    return text;
  }
  final offsets = _taskMarker.allMatches(text).map((m) => m.end - 2).toList();
  var low = 0, high = offsets.length;
  while (high - low > 1) {
    final middle = (low + high) ~/ 2;
    final probe = _checkboxes(
      _flipMarkers(text, offsets.getRange(low, middle)),
    );
    if (probe.length != original.length) return text;
    if (probe[index] != original[index]) {
      high = middle;
    } else {
      low = middle;
    }
  }
  if (low >= offsets.length) return text;
  final updated = _flipMarkers(text, [offsets[low]]);
  final probe = _checkboxes(updated);
  return probe.length == original.length && probe[index] == checked
      ? updated
      : text;
}

bool isMarkdownTaskMarker(String text, int offset) {
  if (offset < 0 || offset >= text.length) return false;
  final original = _checkboxes(text);
  final changed = _checkboxes(_flipMarkers(text, [offset]));
  if (original.length != changed.length) return false;
  for (var i = 0; i < original.length; i++) {
    if (original[i] != changed[i]) return true;
  }
  return false;
}
