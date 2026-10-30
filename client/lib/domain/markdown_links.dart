import 'package:markdown/markdown.dart' as md;

/// Keeps percent escapes intact in automatically detected URLs.
class MarkdownAutolinkSyntax extends md.AutolinkExtensionSyntax {
  static final _encodedEscape = RegExp(r'%25([0-9a-fA-F]{2})');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    if (!match[0]!.contains('%')) return super.onMatch(parser, match);
    // Let Markdown retain its URL boundaries and punctuation handling. Isolate
    // the generated anchor so only automatic links receive this correction.
    final linkParser = md.InlineParser(match[0]!, parser.document);
    if (!super.onMatch(linkParser, match)) return false;
    final consumed = linkParser.pos;
    final anchor = linkParser.parse().first as md.Element;

    // AutolinkExtensionSyntax uses encodeFull, turning an existing %7C into
    // %257C. Undo that extra encoding only for valid escapes; a literal %25
    // stays %25 and an explicit Markdown link is never decoded here.
    anchor.attributes['href'] = anchor.attributes['href']!.replaceAllMapped(
      _encodedEscape,
      (escape) => '%${escape[1]}',
    );
    parser
      ..addNode(anchor)
      ..consume(consumed);
    return true;
  }
}
