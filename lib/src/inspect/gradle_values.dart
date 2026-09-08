/// One right-hand side, classified.
///
/// The whole point of the fast Gradle parser is knowing the difference between
/// "this is `com.acme.app`" and "this is whatever `appId` happens to be", so a
/// value is never just a nullable string.
sealed class GradleValue {
  const GradleValue();

  /// The literal, or null when this is not one.
  String? get literalOrNull => switch (this) {
    GradleLiteral(:final value) => value,
    GradleExpression() => null,
  };

  bool get isLiteral => this is GradleLiteral;
}

/// A value the parser resolved with certainty.
class GradleLiteral extends GradleValue {
  const GradleLiteral(this.value);

  final String value;

  @override
  String toString() => value;
}

/// A value that is present but not a literal.
///
/// A variable, an `ext` property, a string interpolation, a function call.
/// Carries the source text so the uncertainty report can quote it back.
class GradleExpression extends GradleValue {
  const GradleExpression(this.source);

  final String source;

  @override
  String toString() => source;
}

/// Reads statements out of a Gradle block body.
///
/// Deliberately line-oriented and conservative: it recognises the shapes both
/// dialects actually use and declines everything else, because a parser that
/// stretches to cover one more shape is a parser that starts guessing.
abstract final class GradleValues {
  /// Reads `name = "value"` (KTS, and Groovy's assignment form) or
  /// `name "value"` (Groovy's method-call form).
  ///
  /// Returns null when [name] is not set in [body] at all, which callers must
  /// distinguish from a non-literal value.
  static GradleValue? property(String body, String name) {
    final match = RegExp(
      '(?:^|\\n)\\s*(?:$name)\\s*(?:=\\s*|\\s+)([^\\n]+)',
    ).firstMatch(body);
    if (match == null) return null;
    return classify(match.group(1)!);
  }

  /// Reads an integer property such as `compileSdk = 36`.
  static int? intProperty(String body, String name) {
    final value = property(body, name);
    final literal = value?.literalOrNull;
    if (literal != null) return int.tryParse(literal);
    // `compileSdk = flutter.compileSdkVersion` is the Flutter default and is
    // not something the fast path can resolve.
    return null;
  }

  /// Classifies a right-hand side.
  static GradleValue classify(String raw) {
    var text = raw.trim();
    // Strip a trailing line comment, but only outside a string.
    text = _stripTrailingComment(text);
    if (text.endsWith(';')) text = text.substring(0, text.length - 1).trim();

    final literal = stringLiteral(text);
    if (literal != null) return GradleLiteral(literal);
    if (RegExp(r'^-?\d+$').hasMatch(text)) return GradleLiteral(text);
    if (text == 'true' || text == 'false') return GradleLiteral(text);
    return GradleExpression(text);
  }

  /// The content of a plain string literal, or null if [text] is not one.
  ///
  /// A Groovy GString containing `${…}` is not a literal: its value depends on
  /// something the parser cannot see.
  static String? stringLiteral(String text) {
    final trimmed = text.trim();
    if (trimmed.length < 2) return null;
    final quote = trimmed[0];
    if (quote != '"' && quote != "'") return null;
    if (!trimmed.endsWith(quote)) return null;
    final inner = trimmed.substring(1, trimmed.length - 1);
    if (inner.contains(quote) && !inner.contains('\\$quote')) return null;
    if (inner.contains(r'$')) return null;
    return inner.replaceAll('\\$quote', quote);
  }

  /// Reads `flavorDimensions` in all four shapes both dialects allow:
  /// `+= "env"`, `= listOf("env")`, `= ["env"]`, and Groovy's `"env"`.
  static ({List<String> names, List<String> expressions}) flavorDimensions(
    String body,
  ) {
    final names = <String>[];
    final expressions = <String>[];
    for (final match in RegExp(
      r'(?:^|\n)\s*flavorDimensions\s*(?:\+=|=)?\s*([^\n]+)',
    ).allMatches(body)) {
      final raw = _stripTrailingComment(match.group(1)!.trim());
      final items = _listItems(raw);
      for (final item in items) {
        final literal = stringLiteral(item);
        if (literal != null) {
          names.add(literal);
        } else if (item.trim().isNotEmpty) {
          expressions.add(item.trim());
        }
      }
    }
    return (names: names, expressions: expressions);
  }

  /// Splits a list-ish right-hand side into its items.
  ///
  /// Handles `listOf("a", "b")`, `["a", "b"]`, `arrayOf(...)`, `setOf(...)` and
  /// a bare `"a", "b"`.
  static List<String> _listItems(String raw) {
    var text = raw.trim();
    final call = RegExp(
      r'^(?:listOf|arrayOf|setOf|mutableListOf)\s*\((.*)\)$',
    ).firstMatch(text);
    if (call != null) {
      text = call.group(1)!;
    } else if (text.startsWith('[') && text.endsWith(']')) {
      text = text.substring(1, text.length - 1);
    }
    return _splitTopLevel(text, ',');
  }

  /// Reads `resValue("string", "app_name", "Acme")` in both dialects.
  static ({Map<String, String> values, List<String> expressions}) resValues(
    String body,
  ) {
    final values = <String, String>{};
    final expressions = <String>[];
    for (final match in RegExp(
      r'(?:^|\n)\s*resValue\s*\(?([^\n]+)',
    ).allMatches(body)) {
      var args = _stripTrailingComment(match.group(1)!.trim());
      if (args.endsWith(')')) args = args.substring(0, args.length - 1);
      final parts = _splitTopLevel(args, ',');
      if (parts.length < 3) continue;
      final key = stringLiteral(parts[1]);
      final value = stringLiteral(parts[2]);
      if (key == null) {
        expressions.add(args);
        continue;
      }
      if (value == null) {
        expressions.add('resValue $key = ${parts[2].trim()}');
        continue;
      }
      values[key] = value;
    }
    return (values: values, expressions: expressions);
  }

  /// Reads the name a `signingConfig` statement references.
  ///
  /// `signingConfig = signingConfigs.getByName("release")` (KTS) and
  /// `signingConfig signingConfigs.release` (Groovy).
  static String? signingConfigReference(String body) {
    final match = RegExp(
      '''(?:^|\\n)\\s*signingConfig\\s*(?:=\\s*|\\s+)([^\\n]+)''',
    ).firstMatch(body);
    if (match == null) return null;
    final raw = _stripTrailingComment(match.group(1)!.trim());
    final byName = RegExp(
      '''getByName\\s*\\(\\s*["']([^"']+)["']''',
    ).firstMatch(raw);
    if (byName != null) return byName.group(1);
    final dotted = RegExp(
      r'signingConfigs\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)',
    ).firstMatch(raw);
    if (dotted != null) return dotted.group(1);
    final indexed = RegExp(
      '''signingConfigs\\s*\\[\\s*["']([^"']+)["']''',
    ).firstMatch(raw);
    return indexed?.group(1);
  }

  /// Splits on [separator] at paren/bracket depth zero, ignoring separators
  /// inside strings.
  static List<String> _splitTopLevel(String text, String separator) {
    final parts = <String>[];
    var depth = 0;
    var start = 0;
    var index = 0;
    while (index < text.length) {
      final char = text[index];
      if (char == '"' || char == "'") {
        index = _skipString(text, index);
        continue;
      }
      if (char == '(' || char == '[' || char == '{') depth++;
      if (char == ')' || char == ']' || char == '}') depth--;
      if (char == separator && depth == 0) {
        parts.add(text.substring(start, index));
        start = index + 1;
      }
      index++;
    }
    if (start < text.length) parts.add(text.substring(start));
    return parts.where((p) => p.trim().isNotEmpty).toList();
  }

  static int _skipString(String text, int index) {
    final quote = text[index];
    var i = index + 1;
    while (i < text.length) {
      if (text[i] == r'\') {
        i += 2;
        continue;
      }
      if (text[i] == quote) return i + 1;
      i++;
    }
    return text.length;
  }

  /// Removes a `//` comment that is not inside a string.
  static String _stripTrailingComment(String text) {
    var index = 0;
    while (index < text.length) {
      final char = text[index];
      if (char == '"' || char == "'") {
        index = _skipString(text, index);
        continue;
      }
      if (char == '/' && index + 1 < text.length && text[index + 1] == '/') {
        return text.substring(0, index).trim();
      }
      index++;
    }
    return text.trim();
  }
}
