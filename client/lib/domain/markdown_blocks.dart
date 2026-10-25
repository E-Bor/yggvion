/// CommonMark fences: closing markers must match the opening character and
/// contain at least as many markers. Shorter fences may be part of the code.
class MarkdownFence {
  const MarkdownFence(this.marker);
  final String marker;

  static MarkdownFence? open(String line) {
    final match = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$').firstMatch(line);
    if (match == null || (match[1]![0] == '`' && match[2]!.contains('`'))) {
      return null;
    }
    return MarkdownFence(match[1]!);
  }

  bool closes(String line) => RegExp(
    '^ {0,3}${RegExp.escape(marker[0])}{${marker.length},}[ \\t]*\$',
  ).hasMatch(line);
}

/// Keep intentional whitespace within a document, but at most one final newline.
String normalizeMarkdownEnding(String value) =>
    value.replaceFirst(RegExp(r'(?:\r?\n[ \t]*)+$'), '\n');
