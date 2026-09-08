/// A `lib/main_*.dart` entrypoint.
class DartEntrypoint {
  const DartEntrypoint({required this.path, required this.suffix});

  /// Relative path, e.g. `lib/main_dev.dart`.
  final String path;

  /// The part after `main_`, e.g. `dev`.
  ///
  /// Note this is not necessarily a flavor name: a project with flavors
  /// `development`/`production` often has `main_dev.dart`/`main_prod.dart`, so
  /// matching entrypoints to flavors is inference, not a lookup.
  final String suffix;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'path': path,
    'suffix': suffix,
  };
}

/// What `lib/` and `dart_defines/` say.
class DartModel {
  const DartModel({
    this.entrypoints = const <String, DartEntrypoint>{},
    this.dartDefineFiles = const <String, Map<String, String>>{},
    this.defaultEntrypoint,
    this.packageName,
    this.version,
  });

  /// Keyed by [DartEntrypoint.suffix].
  final Map<String, DartEntrypoint> entrypoints;

  /// Parsed `dart_defines/<name>.json`, keyed by name without extension.
  final Map<String, Map<String, String>> dartDefineFiles;

  /// `lib/main.dart`, when it exists.
  final String? defaultEntrypoint;

  /// `name` from pubspec.yaml.
  final String? packageName;

  /// `version` from pubspec.yaml, the source of truth for version and build.
  final String? version;

  /// The entrypoint for [flavor], matched exactly then by common abbreviation.
  ///
  /// Returns null rather than picking a plausible file: a wrong entrypoint
  /// produces a build that runs the wrong configuration and looks fine.
  DartEntrypoint? entrypointFor(String flavor) {
    final exact = entrypoints[flavor];
    if (exact != null) return exact;
    for (final abbreviation in _abbreviations[flavor] ?? const <String>[]) {
      final match = entrypoints[abbreviation];
      if (match != null) return match;
    }
    return null;
  }

  /// Conventional short forms. Deliberately small: this is the difference
  /// between a helpful match and a confident mistake.
  static const Map<String, List<String>> _abbreviations =
      <String, List<String>>{
        'development': <String>['dev'],
        'production': <String>['prod'],
        'staging': <String>['stg', 'stage'],
        'dev': <String>['development'],
        'prod': <String>['production'],
      };

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (packageName != null) 'packageName': packageName,
    if (version != null) 'version': version,
    if (defaultEntrypoint != null) 'defaultEntrypoint': defaultEntrypoint,
    'entrypoints': <String, dynamic>{
      for (final key in entrypoints.keys.toList()..sort())
        key: entrypoints[key]!.toJson(),
    },
    'dartDefineFiles': <String, dynamic>{
      for (final key in dartDefineFiles.keys.toList()..sort())
        key: <String, dynamic>{
          for (final k in dartDefineFiles[key]!.keys.toList()..sort())
            k: dartDefineFiles[key]![k],
        },
    },
  };
}
