import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Content hashing for change detection on managed files.
///
/// Prefixed with the algorithm so the lockfile can migrate later without
/// guessing what an unprefixed digest was.
abstract final class ContentHash {
  static const String prefix = 'sha256:';

  static String of(String content) =>
      '$prefix${sha256.convert(utf8.encode(content))}';

  /// Compares a hash against content, tolerating a null (never-recorded) hash.
  static bool matches(String? hash, String content) =>
      hash != null && hash == of(content);
}
