/// A `header { … }` region found in a Gradle build file.
class GradleBlock {
  const GradleBlock({
    required this.header,
    required this.body,
    required this.headerStart,
    required this.bodyStart,
    required this.bodyEnd,
  });

  /// Everything on the line(s) before the opening brace, trimmed.
  ///
  /// `productFlavors`, `create("dev")`, `getByName("release")` — the dialect
  /// difference lives here rather than in the scanner.
  final String header;

  /// Text between the braces, exclusive.
  final String body;

  /// Offset of the first character of [header] in the original source.
  final int headerStart;

  /// Offset just after the opening brace.
  final int bodyStart;

  /// Offset of the closing brace.
  final int bodyEnd;

  /// The bare name a header declares, unwrapping the KTS call forms.
  ///
  /// `create("dev")` -> `dev`, `getByName("release")` -> `release`,
  /// `dev` -> `dev`. Returns null when the header is not a simple declaration.
  String? get declaredName {
    final trimmed = header.trim();
    final call = RegExp(
      r'''^(?:create|register|maybeCreate|getByName|named)\s*\(\s*["']([^"']+)["']''',
    ).firstMatch(trimmed);
    if (call != null) return call.group(1);
    if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(trimmed)) return trimmed;
    // Groovy allows a quoted name: `"dev" { … }`.
    final quoted = RegExp(r'''^["']([^"']+)["']$''').firstMatch(trimmed);
    return quoted?.group(1);
  }

  /// True when the header is something the parser cannot name — a loop, a
  /// conditional, a closure over a computed list.
  bool get isDynamic => declaredName == null;

  @override
  String toString() => '$header { … }';
}

/// Brace-matching over Gradle sources, aware of strings and comments.
///
/// Not regex over the whole file: `productFlavors` appears inside comments and
/// strings often enough that a naive match produces confident nonsense, and
/// nested braces make a non-structural approach wrong on the cases that matter.
abstract final class GradleScanner {
  /// Finds the top-level blocks inside [source] between [start] and [end].
  ///
  /// Only one level deep — callers recurse into [GradleBlock.body] for nested
  /// blocks, which keeps offsets meaningful at every level.
  static List<GradleBlock> blocksIn(String source, {int start = 0, int? end}) {
    final limit = end ?? source.length;
    final blocks = <GradleBlock>[];
    var index = start;
    var statementStart = start;

    while (index < limit) {
      final skipped = _skipInert(source, index, limit);
      if (skipped != index) {
        // A comment or string is never part of a header we want to keep, but
        // a string inside `create("dev")` is, so only reset the statement
        // boundary for comments.
        if (_isCommentStart(source, index)) {
          if (statementStart == index) statementStart = skipped;
        }
        index = skipped;
        continue;
      }

      final char = source[index];
      if (char == '{') {
        final header = source.substring(statementStart, index).trim();
        final bodyStart = index + 1;
        final bodyEnd = _matchBrace(source, index, limit);
        if (bodyEnd == -1) break;
        blocks.add(
          GradleBlock(
            header: _lastStatement(header),
            body: source.substring(bodyStart, bodyEnd),
            headerStart: statementStart,
            bodyStart: bodyStart,
            bodyEnd: bodyEnd,
          ),
        );
        index = bodyEnd + 1;
        statementStart = index;
        continue;
      }

      if (char == '\n' || char == ';' || char == '}') {
        index++;
        statementStart = index;
        continue;
      }

      index++;
    }
    return blocks;
  }

  /// Finds the first block whose [GradleBlock.declaredName] is [name].
  static GradleBlock? findBlock(String source, String name, {int start = 0}) {
    for (final block in blocksIn(source, start: start)) {
      if (block.declaredName == name) return block;
    }
    return null;
  }

  /// The offset just past `}` matching the `{` at [openIndex], or -1.
  static int _matchBrace(String source, int openIndex, int limit) {
    var depth = 0;
    var index = openIndex;
    while (index < limit) {
      final skipped = _skipInert(source, index, limit);
      if (skipped != index) {
        index = skipped;
        continue;
      }
      final char = source[index];
      if (char == '{') {
        depth++;
      } else if (char == '}') {
        depth--;
        if (depth == 0) return index;
      }
      index++;
    }
    return -1;
  }

  /// Advances past a comment or string literal starting at [index].
  ///
  /// Returns [index] unchanged when there is nothing to skip, which is how the
  /// callers above distinguish "inert text" from "code".
  static int _skipInert(String source, int index, int limit) {
    if (index >= limit) return index;
    final char = source[index];

    if (char == '/' && index + 1 < limit) {
      final next = source[index + 1];
      if (next == '/') {
        var i = index + 2;
        while (i < limit && source[i] != '\n') {
          i++;
        }
        return i;
      }
      if (next == '*') {
        var i = index + 2;
        while (i + 1 < limit && !(source[i] == '*' && source[i + 1] == '/')) {
          i++;
        }
        return (i + 2).clamp(0, limit);
      }
    }

    if (char == '"' || char == "'") {
      // Groovy and KTS both have triple-quoted strings, which may contain
      // unescaped quotes and braces.
      if (index + 2 < limit &&
          source[index + 1] == char &&
          source[index + 2] == char) {
        final close = source.indexOf(char * 3, index + 3);
        return close == -1 ? limit : close + 3;
      }
      var i = index + 1;
      while (i < limit) {
        if (source[i] == r'\') {
          i += 2;
          continue;
        }
        if (source[i] == char) return i + 1;
        if (source[i] == '\n') return i;
        i++;
      }
      return limit;
    }

    return index;
  }

  static bool _isCommentStart(String source, int index) =>
      index + 1 < source.length &&
      source[index] == '/' &&
      (source[index + 1] == '/' || source[index + 1] == '*');

  /// Keeps only the final statement of a multi-statement header fragment.
  ///
  /// Text before a block often includes preceding statements; the header is
  /// whatever sits immediately before the brace.
  static String _lastStatement(String header) {
    final lines = header.split('\n');
    for (var i = lines.length - 1; i >= 0; i--) {
      final line = lines[i].trim();
      if (line.isNotEmpty) return line;
    }
    return '';
  }
}
