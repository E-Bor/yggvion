import 'models.dart';

String _normalized(String text) =>
    text.trim().toLowerCase().replaceAll('ё', 'е');
String _escape(String text) =>
    text.replaceAllMapped(RegExp(r'[\\\[\]|]'), (m) => '\\${m[0]}');
String _unescape(String text) =>
    text.replaceAllMapped(RegExp(r'\\([\\\[\]|])'), (m) => m[1]!);

class WikiLink {
  const WikiLink(this.start, this.end, this.target, this.label);
  final int start, end;
  final String target;
  final String? label;
  static final pattern = RegExp(r'\[\[((?:\\[^\r\n]|[^\]\\\r\n])+)\]\]');

  static WikiLink fromMatch(Match match) {
    final inner = match[1]!;
    var separator = -1;
    for (var i = 0; i < inner.length; i++) {
      if (inner[i] == '\\') {
        i++;
      } else if (inner[i] == '|') {
        separator = i;
        break;
      }
    }
    return WikiLink(
      match.start,
      match.end,
      _unescape(separator < 0 ? inner : inner.substring(0, separator)).trim(),
      separator < 0 ? null : _unescape(inner.substring(separator + 1)),
    );
  }

  static String format(String target, {String? label}) =>
      '[[${_escape(target)}${label == null ? '' : '|${_escape(label)}'}]]';

  static Iterable<WikiLink> inMarkdown(String text) sync* {
    final protected = _codeRanges(text);
    for (final match in pattern.allMatches(text)) {
      if (!_escaped(text, match.start) &&
          !protected.any((r) => match.start >= r.$1 && match.start < r.$2)) {
        yield fromMatch(match);
      }
    }
  }
}

/// The incomplete link around a collapsed caret. Code and escaped brackets
/// remain literal Markdown, and selection never consumes text after the link.
class WikiQuery {
  const WikiQuery(this.start, this.end, this.query);
  final int start, end;
  final String query;

  static WikiQuery? at(String text, int caret) {
    if (caret < 2 || caret > text.length) return null;
    final start = text.lastIndexOf('[[', caret - 2);
    if (start < 0 || _escaped(text, start)) return null;
    final query = text.substring(start + 2, caret);
    if (query.length > 500 || RegExp(r'[\[\]\r\n|]').hasMatch(query)) {
      return null;
    }
    if (_codeRanges(text).any((r) => start >= r.$1 && start < r.$2)) {
      return null;
    }
    String? inlineFence;
    final lineStart = text.lastIndexOf('\n', start) + 1;
    for (final marker in RegExp(
      r'(?<!\\)(`+)',
    ).allMatches(text.substring(lineStart, start))) {
      inlineFence = inlineFence == marker[0] ? null : inlineFence ?? marker[0];
    }
    if (inlineFence != null) return null;
    final close = text.indexOf(']]', caret);
    final end =
        close >= 0 &&
            !RegExp(r'[\[\]\r\n]').hasMatch(text.substring(caret, close))
        ? close + 2
        : caret;
    return WikiQuery(start, end, _unescape(query));
  }
}

bool _escaped(String text, int offset) {
  var count = 0;
  while (offset > 0 && text[--offset] == '\\') {
    count++;
  }
  return count.isOdd;
}

List<(int, int)> _codeRanges(String text) {
  final ranges = <(int, int)>[];
  String? fence;
  var fenceStart = 0, offset = 0;
  for (final line in text.split('\n')) {
    final marker = RegExp(r'^ {0,3}(`{3,}|~{3,})').firstMatch(line)?[1];
    if (fence == null && marker != null) {
      fence = marker;
      fenceStart = offset;
    } else if (fence != null &&
        marker != null &&
        marker[0] == fence[0] &&
        marker.length >= fence.length &&
        line.trim() == marker) {
      ranges.add((fenceStart, offset + line.length));
      fence = null;
    } else if (fence == null &&
        (line.startsWith('    ') || line.startsWith('\t'))) {
      ranges.add((offset, offset + line.length));
    }
    offset += line.length + 1;
  }
  if (fence != null) ranges.add((fenceStart, text.length + 1));
  // Matched inline code, including code spans crossing a line break.
  for (final match in RegExp(r'(`+)([\s\S]*?)\1').allMatches(text)) {
    if (!_escaped(text, match.start)) ranges.add((match.start, match.end));
  }
  return ranges;
}

/// Titles are readable in Markdown. Folder paths disambiguate equal names;
/// only equal names in the same folder need the existing stable note ID.
class WikiNoteIndex {
  factory WikiNoteIndex(Snapshot snapshot) =>
      _cache[snapshot] ??= WikiNoteIndex._(snapshot);
  static final _cache = Expando<WikiNoteIndex>();

  WikiNoteIndex._(this.snapshot) {
    for (final folder in snapshot.noteFolders) {
      folders[folder.id] = folder.title;
    }
    for (final note in snapshot.notes) {
      byId[note.id] = note;
      final label = note.displayLabel;
      labels[note.id] = label;
      (byTarget[_normalized(label)] ??= []).add(note);
      final path = '${folderLabel(note)}/$label';
      (byTarget[_normalized(path)] ??= []).add(note);
    }
  }
  final Snapshot snapshot;
  final folders = <String, String>{};
  final byId = <String, Note>{};
  final labels = <String, String>{};
  final byTarget = <String, List<Note>>{};

  String folderLabel(Note note) => note.pinned.isNotEmpty
      ? 'Закреплённые'
      : folders[note.folderId] ?? 'Без папки';

  List<Note> matches(String target) {
    if (target.startsWith('note:')) {
      final note = byId[target.substring(5)];
      return note == null ? [] : [note];
    }
    return (byTarget[_normalized(target)] ?? []).toSet().toList();
  }

  Note? resolve(String target) => matches(target).singleOrNull;

  String targetFor(Note note) {
    final label = labels[note.id]!;
    if (resolve(label)?.id == note.id) return label;
    final path = '${folderLabel(note)}/$label';
    if (resolve(path)?.id == note.id) return path;
    return 'note:${note.id}';
  }

  String linkFor(Note note, {String? alias}) {
    final target = targetFor(note);
    return WikiLink.format(
      target,
      label: alias ?? (target.startsWith('note:') ? labels[note.id] : null),
    );
  }

  List<Note> search(
    String query, {
    int limit = 40,
    String? excludeId,
    Set<String>? onlyIds,
  }) {
    final words = _normalized(
      query,
    ).split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final result = byId.values.where((note) {
      if (note.id == excludeId ||
          (onlyIds != null && !onlyIds.contains(note.id))) {
        return false;
      }
      final title = _normalized('${labels[note.id]} ${folderLabel(note)}');
      return words.every(title.contains);
    }).toList();
    final prefix = _normalized(query);
    result.sort((a, b) {
      final left = _normalized(labels[a.id]!);
      final right = _normalized(labels[b.id]!);
      final rank = (left.startsWith(prefix) ? 0 : 1).compareTo(
        right.startsWith(prefix) ? 0 : 1,
      );
      return rank != 0 ? rank : left.compareTo(right);
    });
    return result.take(limit).toList();
  }

  String relink(String text, WikiNoteIndex after) {
    final result = StringBuffer();
    var offset = 0;
    for (final link in WikiLink.inMarkdown(text)) {
      result.write(text.substring(offset, link.start));
      final before = resolve(link.target);
      final note = before == null ? null : after.byId[before.id];
      result.write(
        note == null ||
                link.target.startsWith('note:') ||
                (after.resolve(link.target)?.id == note.id &&
                    before!.displayLabel == note.displayLabel)
            ? text.substring(link.start, link.end)
            : after.linkFor(note, alias: link.label),
      );
      offset = link.end;
    }
    result.write(text.substring(offset));
    return result.toString();
  }
}
