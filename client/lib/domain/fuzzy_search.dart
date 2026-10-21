import 'dart:math' as math;
import 'models.dart';

List<String> searchWords(String query) => RegExp(
  r'[\p{L}\p{N}_]+',
  unicode: true,
).allMatches(query.toLowerCase()).map((m) => m[0]!).take(20).toList();

String quoteSearchWord(String word) => '"${word.replaceAll('"', '""')}"';

String prefixSearchQuery(List<String> words) =>
    words.map((word) => '${quoteSearchWord(word)}*').join(' AND ');

/// Bounded optimal-string-alignment distance: insertion, deletion, replacement
/// and an adjacent transposition each count as one typo. Operates on code points.
/// With [prefix], the untyped suffix of [b] does not count as missing letters.
int typoDistance(String a, String b, int limit, {bool prefix = false}) {
  final left = a.replaceAll('ё', 'е').runes.toList();
  final candidate = b.replaceAll('ё', 'е').runes;
  // A matching prefix cannot consume more than query length + allowed edits.
  final right = (prefix ? candidate.take(left.length + limit) : candidate)
      .toList();
  if (left.length - right.length > limit ||
      (!prefix && right.length - left.length > limit)) {
    return limit + 1;
  }
  if (left.isEmpty) return prefix ? 0 : right.length;
  if (right.isEmpty) return left.length;
  var previous = List.generate(right.length + 1, (i) => i);
  List<int>? beforePrevious;
  for (var i = 1; i <= left.length; i++) {
    final row = List.filled(right.length + 1, limit + 1)..[0] = i;
    var minimum = row[0];
    for (
      var j = math.max(1, i - limit);
      j <= math.min(right.length, i + limit);
      j++
    ) {
      row[j] = math.min(
        math.min(row[j - 1] + 1, previous[j] + 1),
        previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1),
      );
      if (i > 1 &&
          j > 1 &&
          left[i - 1] == right[j - 2] &&
          left[i - 2] == right[j - 1]) {
        row[j] = math.min(row[j], beforePrevious![j - 2] + 1);
      }
      minimum = math.min(minimum, row[j]);
    }
    if (minimum > limit) return limit + 1;
    beforePrevious = previous;
    previous = row;
  }
  return prefix ? previous.reduce(math.min) : previous.last;
}

/// One letter always searches exactly. Two letters can have at most one typo,
/// so deleting the entire query can never match every word in the vocabulary.
int wordTypoLimit(String word, int tolerance) {
  final length = word.runes.length;
  return length > 64 ? 0 : math.min(tolerance, math.max(0, length - 1));
}

typedef SearchDocument = ({String title, String body, String category});

SearchDocument? searchDocument(Entity entity) {
  if (entity.deleted) return null;
  switch (entity.kind) {
    case 'note':
      final note = Note(entity);
      final title = note.displayLabel;
      // Keep legacy, no-longer-visible titles searchable without promoting them
      // over the title actually shown in the note list.
      final body = [
        note.content,
        if (note.title != title) note.title,
      ].join('\n');
      return (title: title, body: body, category: 'note');
    case 'task':
      return (
        title: entity.data['title'] as String? ?? '',
        body: entity.data['description'] as String? ?? '',
        category: 'task',
      );
    default:
      return null;
  }
}

class _PrefixNode {
  _PrefixNode(this.edge, [Map<int, _PrefixNode>? children])
    : children = children ?? {};
  List<int> edge;
  Map<int, _PrefixNode> children;
}

/// Compressed prefix tree. A matched prefix covers every completion below it;
/// there is no arbitrary cap on complete vocabulary words that can hide hits.
/// Owned by a persistent worker, never transferred to the UI isolate.
class FuzzyVocabulary {
  FuzzyVocabulary(Iterable<String> words) {
    for (final word in words) {
      _insert(word.runes.take(66).toList());
    }
  }
  final _root = _PrefixNode([]);
  final _cache = <String, List<String>>{};

  void _insert(List<int> word) {
    var parent = _root;
    var offset = 0;
    while (offset < word.length) {
      final child = parent.children[word[offset]];
      if (child == null) {
        parent.children[word[offset]] = _PrefixNode(word.sublist(offset));
        return;
      }
      var shared = 0;
      while (shared < child.edge.length &&
          offset + shared < word.length &&
          child.edge[shared] == word[offset + shared]) {
        shared++;
      }
      if (offset + shared == word.length) return;
      if (shared == child.edge.length) {
        parent = child;
        offset += shared;
        continue;
      }
      final suffix = _PrefixNode(child.edge.sublist(shared), child.children);
      child.edge = child.edge.sublist(0, shared);
      child.children = {suffix.edge.first: suffix};
      final added = _PrefixNode(word.sublist(offset + shared));
      child.children[added.edge.first] = added;
      return;
    }
  }

  List<String> expand(List<String> words, int tolerance) {
    if (words.isEmpty) return const [];
    final expressions = <String>{};
    for (var level = 1; level <= tolerance; level++) {
      expressions.add(
        [
          for (final word in words)
            '(${<String>{word, if (wordTypoLimit(word, level) > 0) ..._prefixes(word, wordTypoLimit(word, level))}.map((prefix) => '${quoteSearchWord(prefix)}*').join(' OR ')})',
        ].join(' AND '),
      );
    }
    return expressions.toList();
  }

  List<String> _prefixes(String word, int limit) {
    final cacheKey = '$limit:$word';
    final cached = _cache.remove(cacheKey);
    if (cached != null) {
      _cache[cacheKey] = cached;
      return cached;
    }
    final query = word.replaceAll('ё', 'е').runes.toList();
    final found = <String>[];
    final prefix = <int>[];
    void visit(
      _PrefixNode node,
      List<int> previous,
      List<int>? beforePrevious,
      int? previousChar,
      int depth,
    ) {
      final originalLength = prefix.length;
      try {
        for (final rune in node.edge) {
          final char = rune == 0x451 ? 0x435 : rune; // ё / е
          depth++;
          final row = List.filled(query.length + 1, limit + 1)..[0] = depth;
          var minimum = row[0];
          for (
            var j = math.max(1, depth - limit);
            j <= math.min(query.length, depth + limit);
            j++
          ) {
            row[j] = math.min(
              math.min(row[j - 1] + 1, previous[j] + 1),
              previous[j - 1] + (char == query[j - 1] ? 0 : 1),
            );
            if (beforePrevious != null &&
                j > 1 &&
                char == query[j - 2] &&
                previousChar == query[j - 1]) {
              row[j] = math.min(row[j], beforePrevious[j - 2] + 1);
            }
            minimum = math.min(minimum, row[j]);
          }
          prefix.add(rune);
          if (row.last <= limit) {
            found.add(String.fromCharCodes(prefix));
            return;
          }
          if (minimum > limit || depth >= query.length + limit) return;
          beforePrevious = previous;
          previous = row;
          previousChar = char;
        }
        for (final child in node.children.values) {
          visit(child, previous, beforePrevious, previousChar, depth);
        }
      } finally {
        prefix.length = originalLength;
      }
    }

    final initial = List.generate(query.length + 1, (i) => i);
    for (final child in _root.children.values) {
      visit(child, initial, null, null, 0);
    }
    if (_cache.length >= 64) _cache.remove(_cache.keys.first);
    _cache[cacheKey] = found;
    return found;
  }
}
