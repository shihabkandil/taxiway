import 'dart:io';

import 'package:path/path.dart' as p;

/// Reads `.xcconfig` files, following `#include` chains.
///
/// A flavor's real bundle id often lives in an xcconfig rather than in the
/// build settings, so a reader that stops at `project.pbxproj` sees
/// `$(PRODUCT_BUNDLE_IDENTIFIER)` and learns nothing.
abstract final class XcconfigReader {
  /// Parses one file and everything it includes.
  ///
  /// Later assignments win, matching Xcode: an including file overrides what it
  /// includes.
  static Future<Map<String, String>> read(
    String path, {
    Set<String>? visited,
  }) async {
    final seen = visited ?? <String>{};
    final absolute = p.normalize(path);
    // An include cycle is malformed but not worth crashing over.
    if (!seen.add(absolute)) return <String, String>{};

    final file = File(absolute);
    if (!file.existsSync()) return <String, String>{};

    final settings = <String, String>{};
    for (final line in await file.readAsLines()) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('//')) continue;

      final include = _includePath(trimmed);
      if (include != null) {
        final resolved = p.normalize(
          p.isAbsolute(include)
              ? include
              : p.join(p.dirname(absolute), include),
        );
        settings.addAll(await read(resolved, visited: seen));
        continue;
      }

      final assignment = _assignment(trimmed);
      if (assignment != null) {
        settings[assignment.key] = assignment.value;
      }
    }
    return settings;
  }

  /// Reads every xcconfig under [directory], keyed by path relative to [root].
  static Future<Map<String, Map<String, String>>> readDirectory(
    String root,
    String directory,
  ) async {
    final dir = Directory(p.join(root, directory));
    if (!dir.existsSync()) return <String, Map<String, String>>{};

    final result = <String, Map<String, String>>{};
    for (final entity in dir.listSync().whereType<File>()) {
      if (p.extension(entity.path) != '.xcconfig') continue;
      result[p.relative(entity.path, from: root)] = await read(entity.path);
    }
    return result;
  }

  /// The path from `#include "x.xcconfig"` or `#include? "x.xcconfig"`.
  static String? _includePath(String line) {
    final match = RegExp(
      r'''^#include\??\s+["<]([^">]+)[">]''',
    ).firstMatch(line);
    return match?.group(1);
  }

  /// Splits `KEY = value`, tolerating Xcode's conditional-assignment syntax
  /// (`KEY[sdk=iphoneos*] = value`), which is recorded under the bare key.
  static ({String key, String value})? _assignment(String line) {
    final index = line.indexOf('=');
    if (index <= 0) return null;
    var key = line.substring(0, index).trim();
    final bracket = key.indexOf('[');
    if (bracket > 0) key = key.substring(0, bracket).trim();
    if (key.isEmpty || !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key)) {
      return null;
    }
    var value = line.substring(index + 1).trim();
    final comment = value.indexOf('//');
    if (comment >= 0) value = value.substring(0, comment).trim();
    return (key: key, value: value);
  }

  /// Substitutes `$(VAR)` / `${VAR}` references using [settings].
  ///
  /// Returns null when a reference cannot be resolved, so the caller records an
  /// uncertainty rather than reporting a half-substituted string as fact.
  static String? resolve(
    String value,
    Map<String, String> settings, {
    int depth = 0,
  }) {
    if (depth > 8) return null;
    final pattern = RegExp(r'\$[({]([A-Za-z_][A-Za-z0-9_]*)[)}]');
    if (!pattern.hasMatch(value)) return value;

    var unresolved = false;
    final result = value.replaceAllMapped(pattern, (match) {
      final replacement = settings[match.group(1)];
      if (replacement == null) {
        unresolved = true;
        return match.group(0)!;
      }
      return replacement;
    });
    if (unresolved) return null;
    return resolve(result, settings, depth: depth + 1);
  }
}
