import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// What each layer under `lib/src/` is allowed to import.
///
/// The plan states the direction as `cli -> core -> {inspect, generators} ->
/// platform -> secrets`, with the hard rule that nothing in `core` imports
/// `cli`. Read as a strict left-to-right chain that is not satisfiable — every
/// reader needs `core`'s ProcessRunner and ProjectModel — so it is encoded here
/// as the DAG it describes: `core` is the shared base that depends on nothing
/// internal, `cli` is the outermost layer that may reach anything, and each
/// layer in between names exactly what it may use.
const Map<String, Set<String>> _allowedImports = <String, Set<String>>{
  'core': <String>{},
  'platform': <String>{'core'},
  'inspect': <String>{'core', 'platform'},
  'generators': <String>{'core', 'platform'},
  'secrets': <String>{'core'},
  'doctor': <String>{'core'},
  'cli': <String>{
    'core',
    'inspect',
    'generators',
    'platform',
    'secrets',
    'doctor',
  },
};

/// Layers that may never spawn a process directly.
///
/// Readers and writers must go through `core/io/ProcessRunner`, which is the
/// only reason the whole CLI is testable without Gradle, Ruby, a keychain or
/// Apple credentials.
const Set<String> _noDirectProcess = <String>{'inspect', 'generators'};

List<File> _dartFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'))
    .toList();

/// The `lib/src/<layer>/` a file belongs to, or null if it sits above them.
String? _layerOf(String path) {
  final relative = p.relative(path, from: 'lib/src').replaceAll(r'\', '/');
  final segments = relative.split('/');
  if (segments.length < 2) return null;
  return _allowedImports.containsKey(segments.first) ? segments.first : null;
}

/// The layer an import resolves into, following relative paths.
String? _importedLayer(String fromPath, String import) {
  if (import.startsWith('package:taxiway/src/')) {
    final rest = import.substring('package:taxiway/src/'.length);
    final first = rest.split('/').first;
    return _allowedImports.containsKey(first) ? first : null;
  }
  if (import.startsWith('dart:') || import.startsWith('package:')) return null;
  final resolved = p.normalize(p.join(p.dirname(fromPath), import));
  return _layerOf(resolved);
}

Iterable<String> _importsOf(String source) sync* {
  for (final match
      in RegExp(r'''^\s*import\s+['"]([^'"]+)['"]''', multiLine: true)
          .allMatches(source)) {
    yield match.group(1)!;
  }
}

void main() {
  group('dependency direction: cli -> core -> {inspect, generators} -> '
      'platform -> secrets', () {
    test('every cross-layer import is on the allow-list', () {
      final violations = <String>[];
      for (final file in _dartFiles('lib/src')) {
        final layer = _layerOf(file.path);
        if (layer == null) continue;
        final source = file.readAsStringSync();
        for (final import in _importsOf(source)) {
          final target = _importedLayer(file.path, import);
          if (target == null) continue;
          if (target == layer) continue;
          if (!_allowedImports[layer]!.contains(target)) {
            violations.add(
              '${p.relative(file.path)} ($layer) imports $import ($target); '
              '$layer may import ${_allowedImports[layer]!.join(', ')}',
            );
          }
        }
      }
      expect(violations, isEmpty,
          reason: 'Dependencies must point at the base:\n'
              '${violations.join('\n')}');
    });

    test('nothing in core imports cli', () {
      final violations = <String>[];
      for (final file in _dartFiles('lib/src')) {
        if (_layerOf(file.path) != 'core') continue;
        for (final import in _importsOf(file.readAsStringSync())) {
          if (_importedLayer(file.path, import) == 'cli') {
            violations.add('${p.relative(file.path)} imports $import');
          }
        }
      }
      expect(violations, isEmpty, reason: violations.join('\n'));
    });
  });

  group('process isolation', () {
    test('only core/io may touch dart:io Process', () {
      final violations = <String>[];
      for (final file in _dartFiles('lib/src')) {
        final relative = p.relative(file.path).replaceAll(r'\', '/');
        if (relative.startsWith('lib/src/core/io/')) continue;
        final source = file.readAsStringSync();
        if (RegExp(r'\bProcess\.(start|run|runSync)\b').hasMatch(source)) {
          violations.add('$relative calls Process directly');
        }
      }
      expect(violations, isEmpty,
          reason: 'Use core/io/ProcessRunner:\n${violations.join('\n')}');
    });

    test('readers and writers never spawn processes', () {
      final violations = <String>[];
      for (final file in _dartFiles('lib/src')) {
        final layer = _layerOf(file.path);
        if (layer == null || !_noDirectProcess.contains(layer)) continue;
        final source = file.readAsStringSync();
        if (source.contains('dart:io') &&
            RegExp(r'\bProcess\b').hasMatch(source)) {
          violations.add('${p.relative(file.path)} references Process');
        }
      }
      expect(violations, isEmpty, reason: violations.join('\n'));
    });
  });

  group('redaction is not optional', () {
    test('SystemProcessRunner requires a Redactor', () {
      final source =
          File('lib/src/core/io/process_runner.dart').readAsStringSync();
      // Retrofitting redaction is how secrets leak, so it is a required
      // constructor argument rather than an opt-in.
      expect(source, contains('SystemProcessRunner({required this.redactor})'));
      expect(source, contains('redactor.redactStream'));
    });
  });
}
