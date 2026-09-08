import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/io/process_runner.dart';

/// A failure reported by the Ruby bridge, or by our attempt to run it.
class XcodeprojBridgeException implements Exception {
  XcodeprojBridgeException(this.code, this.message, {this.remedy});

  final String code;
  final String message;
  final String? remedy;

  @override
  String toString() => remedy == null ? message : '$message\n$remedy';
}

/// The Dart side of `tool/ruby/xcodeproj_bridge.rb`.
///
/// One narrow JSON-in / JSON-out contract, used for both reading and writing.
/// Dart never parses `project.pbxproj` itself.
class XcodeprojBridge {
  const XcodeprojBridge({required this.runner, required this.scriptPath});

  final ProcessRunner runner;

  /// Absolute path to the shipped Ruby script.
  final String scriptPath;

  /// Locates the bridge relative to the running package.
  ///
  /// Works from a source checkout and from a `dart pub global activate`
  /// install, both of which keep `tool/` alongside `lib/`.
  static String? locateScript({String? packageRoot}) {
    final candidates = <String>[
      if (packageRoot != null)
        p.join(packageRoot, 'tool/ruby/xcodeproj_bridge.rb'),
      p.join(Directory.current.path, 'tool/ruby/xcodeproj_bridge.rb'),
      p.join(
        p.dirname(p.dirname(Platform.script.toFilePath())),
        'tool/ruby/xcodeproj_bridge.rb',
      ),
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return p.normalize(candidate);
    }
    return null;
  }

  /// Runs `read` and returns the decoded project.
  Future<Map<String, dynamic>> read(String xcodeprojPath) async =>
      _invoke('read', xcodeprojPath);

  Future<Map<String, dynamic>> _invoke(String op, String xcodeprojPath) async {
    final result = await runner.run('ruby', <String>[
      scriptPath,
      op,
      xcodeprojPath,
    ]);

    if (result.notFound) {
      throw XcodeprojBridgeException(
        'ruby_missing',
        'Ruby is not installed or not on PATH.',
        remedy: 'Install Ruby 3.0 or later, then `gem install xcodeproj`.',
      );
    }

    final stdout = result.stdout.trim();
    if (stdout.isEmpty) {
      throw XcodeprojBridgeException(
        'bridge_no_output',
        'The Xcode project bridge produced no output '
            '(exit ${result.exitCode}).',
        remedy: result.stderr.isEmpty ? null : result.stderr,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(stdout);
    } on FormatException {
      throw XcodeprojBridgeException(
        'bridge_bad_output',
        'The Xcode project bridge did not return JSON.',
        remedy: stdout.split('\n').take(3).join('\n'),
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw XcodeprojBridgeException(
        'bridge_bad_output',
        'The Xcode project bridge returned ${decoded.runtimeType}, '
            'not an object.',
      );
    }

    if (decoded['ok'] != true) {
      final error = decoded['error'];
      final map = error is Map
          ? error.cast<String, dynamic>()
          : const <String, dynamic>{};
      throw XcodeprojBridgeException(
        map['code'] as String? ?? 'bridge_error',
        map['message'] as String? ?? 'The Xcode project bridge failed.',
        remedy: map['remedy'] as String?,
      );
    }

    return decoded;
  }
}
