/// A minimal unified diff.
///
/// Enough to show a user what shipway would change before it changes it. Not a
/// general diff library: it exists so a refusal ("you edited this file") can be
/// specific instead of asking the user to guess what moved.
abstract final class TextDiff {
  /// Lines of context to show either side of a change.
  static const int contextLines = 3;

  /// Returns a unified diff of [before] to [after], or an empty string when
  /// they are identical.
  static String unified(
    String before,
    String after, {
    String beforeLabel = 'on disk',
    String afterLabel = 'shipway would write',
  }) {
    if (before == after) return '';

    final a = _lines(before);
    final b = _lines(after);
    final ops = _diff(a, b);
    if (ops.isEmpty) return '';

    final buffer = StringBuffer()
      ..writeln('--- $beforeLabel')
      ..writeln('+++ $afterLabel');

    // Group changes into hunks so an unrelated edit at the top of a large file
    // does not print the whole file.
    var index = 0;
    while (index < ops.length) {
      if (ops[index].kind == _OpKind.same) {
        index++;
        continue;
      }
      var start = index;
      var contextBefore = 0;
      while (start > 0 &&
          ops[start - 1].kind == _OpKind.same &&
          contextBefore < contextLines) {
        start--;
        contextBefore++;
      }

      var end = index;
      while (end < ops.length) {
        if (ops[end].kind != _OpKind.same) {
          end++;
          continue;
        }
        // Keep going only if another change follows within twice the context,
        // otherwise this hunk is finished.
        var lookahead = end;
        var run = 0;
        while (lookahead < ops.length &&
            ops[lookahead].kind == _OpKind.same &&
            run < contextLines * 2) {
          lookahead++;
          run++;
        }
        if (lookahead < ops.length && ops[lookahead].kind != _OpKind.same) {
          end = lookahead;
          continue;
        }
        end += run.clamp(0, contextLines);
        break;
      }

      for (var i = start; i < end && i < ops.length; i++) {
        buffer.writeln(ops[i].render());
      }
      index = end;
      if (index < ops.length) buffer.writeln('...');
    }

    return buffer.toString();
  }

  /// A one-line summary, for a list of files rather than a detailed view.
  static String summarise(String before, String after) {
    if (before == after) return 'unchanged';
    final ops = _diff(_lines(before), _lines(after));
    final added = ops.where((o) => o.kind == _OpKind.add).length;
    final removed = ops.where((o) => o.kind == _OpKind.remove).length;
    return '+$added -$removed';
  }

  static List<String> _lines(String text) {
    final lines = text.split('\n');
    // A trailing newline produces an empty final element that is not a line.
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    return lines;
  }

  /// Longest-common-subsequence diff.
  ///
  /// Quadratic, which is fine: these are build files, not source trees, and a
  /// correct minimal diff matters more here than speed.
  static List<_Op> _diff(List<String> a, List<String> b) {
    final lengths = List<List<int>>.generate(
      a.length + 1,
      (_) => List<int>.filled(b.length + 1, 0),
      growable: false,
    );
    for (var i = a.length - 1; i >= 0; i--) {
      for (var j = b.length - 1; j >= 0; j--) {
        lengths[i][j] = a[i] == b[j]
            ? lengths[i + 1][j + 1] + 1
            : (lengths[i + 1][j] > lengths[i][j + 1]
                  ? lengths[i + 1][j]
                  : lengths[i][j + 1]);
      }
    }

    final ops = <_Op>[];
    var i = 0;
    var j = 0;
    while (i < a.length && j < b.length) {
      if (a[i] == b[j]) {
        ops.add(_Op(_OpKind.same, a[i]));
        i++;
        j++;
      } else if (lengths[i + 1][j] >= lengths[i][j + 1]) {
        ops.add(_Op(_OpKind.remove, a[i]));
        i++;
      } else {
        ops.add(_Op(_OpKind.add, b[j]));
        j++;
      }
    }
    while (i < a.length) {
      ops.add(_Op(_OpKind.remove, a[i++]));
    }
    while (j < b.length) {
      ops.add(_Op(_OpKind.add, b[j++]));
    }
    return ops;
  }
}

enum _OpKind { same, add, remove }

class _Op {
  const _Op(this.kind, this.text);

  final _OpKind kind;
  final String text;

  String render() => switch (kind) {
    _OpKind.same => '  $text',
    _OpKind.add => '+ $text',
    _OpKind.remove => '- $text',
  };
}
