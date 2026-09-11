import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

/// Sets values in an existing `shipway.yaml` without rewriting it.
///
/// `ConfigWriter` renders a whole file, which is right for `import` and wrong
/// for everything else: a config a team has edited carries comments, ordering
/// and choices that a re-render silently discards. The setup commands change
/// one or two `*_ref` fields, so they change one or two lines.
///
/// Never writes a value — only the *name* of one. That is the whole point of
/// the `*_ref` convention, and a patcher that could write a secret into the
/// config would end it.
abstract final class ConfigPatch {
  /// Returns [yaml] with [path] set to [value], creating parents as needed.
  ///
  /// [value] is a name or a plain setting. Passing a credential here is a bug
  /// the type system cannot catch, so callers are the ones that must not.
  static String set(String yaml, List<String> path, Object? value) {
    if (path.isEmpty) throw ArgumentError('A path is required.');

    final editor = YamlEditor(yaml);

    // yaml_edit will not create a missing parent, and creating them one level
    // at a time yields flow style — `signing: {android: {keystore_ref: X}}` —
    // which is valid, unlike the rest of the file, and unpleasant to edit by
    // hand afterwards. So the whole missing tail is built as one block map.
    var depth = path.length - 1;
    while (depth > 0 && !_exists(editor, path.sublist(0, depth))) {
      depth--;
    }
    if (depth == path.length - 1) {
      editor.update(path, value);
      return editor.toString();
    }

    Object? nested = value;
    for (var i = path.length - 1; i > depth; i--) {
      nested = <String, Object?>{path[i]: nested};
    }
    editor.update(
      path.sublist(0, depth + 1),
      wrapAsYamlNode(nested, collectionStyle: CollectionStyle.BLOCK),
    );
    return editor.toString();
  }

  /// Applies several paths in one pass, in order.
  static String setAll(String yaml, Map<List<String>, Object?> values) {
    var result = yaml;
    for (final entry in values.entries) {
      result = set(result, entry.key, entry.value);
    }
    return result;
  }

  static bool _exists(YamlEditor editor, List<String> path) {
    try {
      return editor.parseAt(path).value != null;
    } on Object {
      return false;
    }
  }
}
