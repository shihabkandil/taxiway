import 'comment_style.dart';

/// A located managed region inside a file.
class BlockLocation {
  const BlockLocation({
    required this.start,
    required this.end,
    required this.body,
    required this.indent,
  });

  /// Character offset of the first character of the BEGIN marker line.
  final int start;

  /// Character offset just past the newline ending the END marker line.
  final int end;

  /// The content between the markers, exclusive, with indentation stripped.
  final String body;

  /// Leading whitespace the block was found at, preserved on rewrite so an
  /// injected Gradle block stays aligned inside `android { … }`.
  final String indent;
}

/// Reading, writing and removing shipway's marked regions in files it does not
/// own outright.
///
/// Block-managed files (`build.gradle.kts`, `.gitignore`, `Podfile`,
/// `project.pbxproj`) belong to the user; shipway rewrites only what is between
/// its markers and must never disturb a byte outside them.
abstract final class ManagedBlock {
  static const String beginText =
      'BEGIN shipway (managed) — do not edit. Regenerate with `shipway generate`.';
  static const String endText = 'END shipway';

  /// Matched loosely on the leading phrase so a marker written by an older
  /// version — with different trailing advice — is still recognised as ours.
  static const String beginMarker = 'BEGIN shipway (managed)';
  static const String endMarker = 'END shipway';

  static String beginLine(CommentStyle style) => style.wrap(beginText);

  static String endLine(CommentStyle style) => style.wrap(endText);

  /// Finds shipway's block in [content], or null if there is none.
  ///
  /// Throws [ManagedBlockException] on a malformed pair — an unterminated or
  /// duplicated block is a hand-edit we must not paper over by guessing.
  static BlockLocation? find(String content) {
    final lines = _splitKeepingEnds(content);
    int? beginIndex;
    int? endIndex;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].contains(beginMarker)) {
        if (beginIndex != null) {
          throw ManagedBlockException(
            'Found more than one shipway managed block. '
            'Remove the extra block, or delete both and re-run `shipway generate`.',
          );
        }
        beginIndex = i;
      } else if (lines[i].contains(endMarker) && beginIndex != null) {
        endIndex ??= i;
      }
    }
    if (beginIndex == null) return null;
    if (endIndex == null) {
      throw ManagedBlockException(
        'Found a shipway BEGIN marker with no matching END marker. '
        'Restore the END marker or remove the block.',
      );
    }

    var start = 0;
    for (var i = 0; i < beginIndex; i++) {
      start += lines[i].length;
    }
    var end = start;
    for (var i = beginIndex; i <= endIndex; i++) {
      end += lines[i].length;
    }

    final beginLine = lines[beginIndex];
    final indent = beginLine.substring(
      0,
      beginLine.length - beginLine.trimLeft().length,
    );
    final body = lines
        .sublist(beginIndex + 1, endIndex)
        .join()
        .split('\n')
        .map((l) => l.startsWith(indent) ? l.substring(indent.length) : l)
        .join('\n');

    return BlockLocation(
      start: start,
      end: end,
      body: _stripTrailingNewline(body),
      indent: indent,
    );
  }

  /// Replaces the existing block's body, or inserts a new block.
  ///
  /// [insertAt] is a character offset used only when no block exists yet; when
  /// it is null the block is appended. Existing blocks are replaced in place,
  /// so re-running generation never relocates a region the user has read.
  static String upsert(
    String content, {
    required String body,
    required CommentStyle style,
    int? insertAt,
    String indent = '',
  }) {
    final existing = find(content);
    if (existing != null) {
      return content.replaceRange(
        existing.start,
        existing.end,
        _render(body, style, existing.indent, endsWithNewline: true),
      );
    }
    final rendered = _render(body, style, indent, endsWithNewline: true);
    if (insertAt == null) {
      final separator = content.isEmpty || content.endsWith('\n') ? '' : '\n';
      return '$content$separator$rendered';
    }
    return content.replaceRange(insertAt, insertAt, rendered);
  }

  /// Removes shipway's block entirely, leaving the rest of the file untouched.
  static String remove(String content) {
    final existing = find(content);
    if (existing == null) return content;
    return content.replaceRange(existing.start, existing.end, '');
  }

  /// True when [content] carries a shipway block.
  static bool isPresent(String content) => find(content) != null;

  static String _render(
    String body,
    CommentStyle style,
    String indent, {
    required bool endsWithNewline,
  }) {
    final buffer = StringBuffer()
      ..write(indent)
      ..write(beginLine(style))
      ..write('\n');
    for (final line in _stripTrailingNewline(body).split('\n')) {
      if (line.trim().isEmpty) {
        buffer.write('\n');
      } else {
        buffer
          ..write(indent)
          ..write(line)
          ..write('\n');
      }
    }
    buffer
      ..write(indent)
      ..write(endLine(style));
    if (endsWithNewline) buffer.write('\n');
    return buffer.toString();
  }

  static String _stripTrailingNewline(String value) =>
      value.endsWith('\n') ? value.substring(0, value.length - 1) : value;

  /// Splits into lines that still carry their terminators, so offsets computed
  /// from them map back onto the original string exactly.
  static List<String> _splitKeepingEnds(String content) {
    final lines = <String>[];
    var start = 0;
    for (var i = 0; i < content.length; i++) {
      if (content[i] == '\n') {
        lines.add(content.substring(start, i + 1));
        start = i + 1;
      }
    }
    if (start < content.length) lines.add(content.substring(start));
    return lines;
  }
}

/// A managed block that cannot be interpreted safely.
class ManagedBlockException implements Exception {
  ManagedBlockException(this.message);

  final String message;

  @override
  String toString() => message;
}
