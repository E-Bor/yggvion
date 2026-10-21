import 'dart:math' as math;

List<String> searchWords(String query) => RegExp(
  r'[\p{L}\p{N}_]+',
  unicode: true,
).allMatches(query.toLowerCase()).map((m) => m[0]!).take(20).toList();

String quoteSearchWord(String word) => '"${word.replaceAll('"', '""')}"';

String prefixSearchQuery(List<String> words) =>
    words.map((word) => '${quoteSearchWord(word)}*').join(' AND ');

/// Bounded optimal-string-alignment distance: insertion, deletion, replacement
/// and an adjacent transposition each count as one typo. Operates on code points.
int typoDistance(String a, String b, int limit) {
  final left = a.replaceAll('ё', 'е').runes.toList();
  final right = b.replaceAll('ё', 'е').runes.toList();
  if ((left.length - right.length).abs() > limit) return limit + 1;
  if (left.isEmpty || right.isEmpty) return math.max(left.length, right.length);
  var previous = List.generate(right.length + 1, (i) => i);
  List<int>? beforePrevious;
  for (var i = 1; i <= left.length; i++) {
    final row = List.filled(right.length + 1, limit + 1)..[0] = i;
    var minimum = limit + 1;
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
  return previous.last;
}

typedef SearchTerm = ({String word, int documents});

/// Run away from the UI isolate. FTS still performs document retrieval and
/// ranking; fuzzy matching scans only its vocabulary, never note bodies.
List<String> expandedSearchQueries(
  List<String> words,
  List<SearchTerm> vocabulary,
  int tolerance,
) {
  final variants = <List<({String word, int distance, int documents})>>[];
  for (final word in words) {
    final matches = <({String word, int distance, int documents})>[];
    if (word.runes.length >= 3 && word.runes.length <= 64) {
      for (final term in vocabulary) {
        if (term.word.startsWith(word)) continue; // Already covered by prefix.
        final distance = typoDistance(word, term.word, tolerance);
        if (distance <= tolerance) {
          matches.add((
            word: term.word,
            distance: distance,
            documents: term.documents,
          ));
        }
      }
    }
    matches.sort((a, b) {
      final distance = a.distance.compareTo(b.distance);
      if (distance != 0) return distance;
      final frequency = b.documents.compareTo(a.documents);
      return frequency != 0 ? frequency : a.word.compareTo(b.word);
    });
    variants.add(matches.take(64).toList());
  }
  return [
    for (var distance = 1; distance <= tolerance; distance++)
      [
        for (var i = 0; i < words.length; i++)
          '(${['${quoteSearchWord(words[i])}*', ...variants[i].where((v) => v.distance <= distance).map((v) => quoteSearchWord(v.word))].join(' OR ')})',
      ].join(' AND '),
  ];
}
