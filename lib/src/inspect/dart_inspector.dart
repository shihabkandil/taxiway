import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../core/model/dart_model.dart';
import '../core/model/uncertainty.dart';

class DartInspectResult {
  const DartInspectResult({required this.dart, required this.uncertainties});

  final DartModel dart;
  final List<Uncertainty> uncertainties;
}

/// Reads `lib/main_*.dart` entrypoints, `dart_defines/*.json` and pubspec.
class DartInspector {
  const DartInspector();

  /// `main_common.dart` and similar are shared code, not per-flavor
  /// entrypoints. Treating one as a flavor would invent a flavor that does not
  /// exist.
  static const Set<String> nonFlavorSuffixes = <String>{
    'common',
    'shared',
    'base',
    'app',
    'test',
  };

  Future<DartInspectResult> inspect(String root) async {
    final log = UncertaintyLog();

    final entrypoints = <String, DartEntrypoint>{};
    final libDir = Directory(p.join(root, 'lib'));
    if (libDir.existsSync()) {
      for (final file in libDir.listSync().whereType<File>()) {
        final name = p.basenameWithoutExtension(file.path);
        if (!name.startsWith('main_')) continue;
        final suffix = name.substring('main_'.length);
        if (suffix.isEmpty) continue;
        if (nonFlavorSuffixes.contains(suffix)) {
          log.note(
            field: 'dart.entrypoints.$suffix',
            reason:
                'lib/$name.dart looks like shared code rather than a '
                'flavor entrypoint, so it was not treated as one.',
            remedy: 'If it is a flavor entrypoint, rename the flavor to match.',
            source: 'lib/$name.dart',
          );
          continue;
        }
        entrypoints[suffix] = DartEntrypoint(
          path: p.posix.join('lib', '$name.dart'),
          suffix: suffix,
        );
      }
    }

    final defines = <String, Map<String, String>>{};
    final definesDir = Directory(p.join(root, 'dart_defines'));
    if (definesDir.existsSync()) {
      for (final file in definesDir.listSync().whereType<File>()) {
        if (p.extension(file.path) != '.json') continue;
        final name = p.basenameWithoutExtension(file.path);
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is Map) {
            defines[name] = decoded.map(
              (k, v) => MapEntry(k.toString(), v.toString()),
            );
          }
        } on FormatException catch (e) {
          log.defect(
            field: 'dart.dartDefines.$name',
            reason: 'dart_defines/$name.json is not valid JSON: ${e.message}',
            remedy:
                'Fix the file; taxiway passes it to '
                '`--dart-define-from-file`.',
            source: 'dart_defines/$name.json',
          );
        }
      }
    }

    final pubspec = await _readPubspec(root, log);

    return DartInspectResult(
      dart: DartModel(
        entrypoints: entrypoints,
        dartDefineFiles: defines,
        defaultEntrypoint: File(p.join(root, 'lib/main.dart')).existsSync()
            ? 'lib/main.dart'
            : null,
        packageName: pubspec.name,
        version: pubspec.version,
      ),
      uncertainties: log.build(),
    );
  }

  Future<({String? name, String? version})> _readPubspec(
    String root,
    UncertaintyLog log,
  ) async {
    final file = File(p.join(root, 'pubspec.yaml'));
    if (!file.existsSync()) return (name: null, version: null);
    try {
      final doc = loadYaml(await file.readAsString());
      if (doc is! YamlMap) return (name: null, version: null);
      return (
        name: doc['name']?.toString(),
        version: doc['version']?.toString(),
      );
    } on YamlException catch (e) {
      log.defect(
        field: 'dart.pubspec',
        reason: 'pubspec.yaml could not be parsed: ${e.message}',
        remedy: 'Fix the YAML; taxiway reads the app version from it.',
        source: 'pubspec.yaml',
      );
      return (name: null, version: null);
    }
  }
}
