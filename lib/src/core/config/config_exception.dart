/// A config problem worth showing to a user verbatim.
///
/// Carries a source location when the YAML parser could give us one, because
/// "line 14, column 5" is the difference between a fixable error and a hunt.
class ConfigException implements Exception {
  ConfigException(this.message, {this.path, this.line, this.column, this.hint});

  /// What is wrong, in one sentence.
  final String message;

  /// The config file this came from.
  final String? path;

  final int? line;
  final int? column;

  /// What to do about it.
  final String? hint;

  String get location {
    if (path == null) return '';
    if (line == null) return path!;
    return column == null ? '$path:$line' : '$path:$line:$column';
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    if (path != null) buffer.write('$location: ');
    buffer.write(message);
    if (hint != null) buffer.write('\n$hint');
    return buffer.toString();
  }
}
