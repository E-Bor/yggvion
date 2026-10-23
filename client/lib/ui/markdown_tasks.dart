import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../domain/markdown_tasks.dart';

/// flutter_markdown expects the checkbox directly under li, also in loose lists.
class MarkdownTaskListBuilder extends MarkdownPaddingBuilder {
  @override
  void visitElementBefore(md.Element element) {
    final input = markdownTaskInput(element);
    if (input != null && element.children!.first != input) {
      (element.children!.first as md.Element).children!.remove(input);
      element.children!.insert(0, input);
    }
  }
}

class MarkdownTaskInputFormatter extends TextInputFormatter {
  const MarkdownTaskInputFormatter();

  static final _prefix = RegExp(r'^([ \t]*-[ \t]+\[)[ xX](\][ \t]+)');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (!oldValue.selection.isValid ||
        !oldValue.selection.isCollapsed ||
        !newValue.selection.isCollapsed ||
        !newValue.composing.isCollapsed) {
      return newValue;
    }
    final caret = oldValue.selection.extentOffset;
    if (newValue.text.length != oldValue.text.length + 1 ||
        newValue.selection.extentOffset != caret + 1 ||
        newValue.text != oldValue.text.replaceRange(caret, caret, '\n')) {
      return newValue;
    }
    final start = caret == 0
        ? 0
        : oldValue.text.lastIndexOf('\n', caret - 1) + 1;
    final line = oldValue.text.substring(start, caret);
    final match = _prefix.firstMatch(line);
    if (match == null ||
        !isMarkdownTaskMarker(oldValue.text, start + match[1]!.length)) {
      return newValue;
    }
    // Enter on an empty item leaves the list without adding another checkbox.
    if (line.substring(match.end).trim().isEmpty &&
        (caret == oldValue.text.length || oldValue.text[caret] == '\n')) {
      return TextEditingValue(
        text: oldValue.text.replaceRange(start, caret, ''),
        selection: TextSelection.collapsed(offset: start),
      );
    }
    final prefix = '${match[1]} ${match[2]}';
    return newValue.copyWith(
      text: newValue.text.replaceRange(caret + 1, caret + 1, prefix),
      selection: TextSelection.collapsed(offset: caret + 1 + prefix.length),
    );
  }
}
