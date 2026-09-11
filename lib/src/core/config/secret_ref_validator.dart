import 'dart:convert';

import 'shipway_config.dart';

/// One `*_ref` that looks like it holds a secret rather than naming one.
class SecretRefViolation {
  const SecretRefViolation({required this.path, required this.reason});

  /// Dotted config path, e.g. `apps.main.signing.ios.api_key.p8_ref`.
  final String path;

  /// Why we think this is a value, not a name.
  final String reason;

  @override
  String toString() => '$path $reason';
}

/// Rejects configs whose `*_ref` fields contain secrets instead of secret names.
///
/// This is the single most likely user mistake — pasting the key where its name
/// belongs — and it matters more now that import *derives* these fields from a
/// project it just read. A committed `shipway.yaml` with a `.p8` in it is a
/// disclosed key.
abstract final class SecretRefValidator {
  /// A name longer than this is not a name.
  static const int maxNameLength = 100;

  /// Decoded base64 above this size is payload, not an identifier.
  static const int maxDecodedBytes = 64;

  /// Substrings that only ever appear in credential material.
  static const List<String> credentialMarkers = <String>[
    '-----BEGIN',
    'PRIVATE KEY',
    'ssh-rsa',
    'AIza', // Google API key prefix
    'xoxb-', // Slack bot token
    'xoxp-',
    'ghp_', // GitHub personal access token
    'AKIA', // AWS access key id
  ];

  /// Environment-variable-shaped names: what a `*_ref` should be.
  static final RegExp _nameShape = RegExp(r'^[A-Za-z_][A-Za-z0-9_.-]*$');

  static List<SecretRefViolation> validate(ShipwayConfig config) {
    final violations = <SecretRefViolation>[];
    for (final ref in secretRefsOf(config)) {
      final reason = reasonToReject(ref.value);
      if (reason != null) {
        violations.add(SecretRefViolation(path: ref.path, reason: reason));
      }
    }
    return violations;
  }

  /// Why [value] cannot be a secret *name*, or null if it is a plausible one.
  static String? reasonToReject(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return 'is empty; give the name of an env var or keychain key';
    }

    for (final marker in credentialMarkers) {
      if (trimmed.contains(marker)) {
        return 'contains "$marker" — that is the secret itself, not its name';
      }
    }
    if (trimmed.length > maxNameLength) {
      return 'is ${trimmed.length} characters; a secret name should be under '
          '$maxNameLength. Put the value in your environment or keychain and '
          'name it here';
    }
    if (trimmed.contains('\n')) {
      return 'spans multiple lines; a secret name is a single word';
    }
    final decoded = _decodedByteLength(trimmed);
    if (decoded != null && decoded > maxDecodedBytes) {
      return 'decodes as base64 of $decoded bytes — that is a payload, not a name';
    }
    if (!_nameShape.hasMatch(trimmed)) {
      return 'is not a valid secret name; use letters, digits, `_`, `.` or `-`';
    }
    return null;
  }

  /// Byte length of [value] read as base64, or null if it is not base64.
  ///
  /// Short identifiers are frequently accidental valid base64, so the caller
  /// only rejects on size.
  static int? _decodedByteLength(String value) {
    if (value.length % 4 != 0 || value.length < 8) return null;
    if (!RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(value)) return null;
    try {
      return base64.decode(value).length;
    } on FormatException {
      return null;
    }
  }
}
