import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config/taxiway_config.dart';
import '../core/gradle/gradle_layout.dart';
import 'android_flavor_generator.dart';
import 'dart_generators.dart';
import 'generated_file.dart';
import 'ios_generators.dart';
import 'resolve_app.dart';

/// The generators taxiway ships, and how to build the input they need.
abstract final class GeneratorRegistry {
  /// Ordered so a `--dry-run` plan reads platform by platform.
  static const List<Generator> all = <Generator>[
    AndroidFlavorGenerator(),
    IosSchemeGenerator(),
    XcconfigGenerator(),
    DartEntrypointGenerator(),
    DartDefinesGenerator(),
    GitignoreGenerator(),
  ];

  /// Named groups accepted by `taxiway generate <group>`.
  static const Map<String, List<String>> groups = <String, List<String>>{
    'flavors': <String>[
      'android-flavors',
      'ios-schemes',
      'xcconfigs',
      'entrypoints',
      'dart-defines',
    ],
    'all': <String>[
      'android-flavors',
      'ios-schemes',
      'xcconfigs',
      'entrypoints',
      'dart-defines',
      'gitignore',
    ],
  };

  /// Resolves a group name or a generator name to generators.
  ///
  /// Returns null for an unknown name so the caller can list what is valid,
  /// which is more use than an exception.
  static List<Generator>? select(String name) {
    final group = groups[name];
    if (group != null) {
      return all.where((g) => group.contains(g.name)).toList();
    }
    final single = all.where((g) => g.name == name).toList();
    return single.isEmpty ? null : single;
  }

  static List<String> get names => <String>[
    ...groups.keys,
    ...all.map((g) => g.name),
  ];

  /// Builds the generator input for [config] against the project at [root].
  ///
  /// Two things must come from the project rather than the config: which Gradle
  /// dialect to emit, and the existing scheme to base new ones on. taxiway has
  /// no opinion about either — it must match what is already there.
  static ResolvedApp resolveFor(
    TaxiwayConfig config,
    String root, {
    String? appId,
  }) => ResolveApp.resolve(
    config,
    appId: appId,
    gradleDsl: GradleLayout.dslFor(root),
    iosSchemeTemplate: readSchemeTemplate(root),
  );

  /// The project's `Runner.xcscheme`, or null when there is none to copy.
  static String? readSchemeTemplate(String root) {
    final file = File(
      p.join(root, IosSchemeGenerator.schemeDirectory, 'Runner.xcscheme'),
    );
    return file.existsSync() ? file.readAsStringSync() : null;
  }
}
