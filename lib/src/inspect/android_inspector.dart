import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/io/process_runner.dart';
import '../core/model/android_model.dart';
import '../core/model/uncertainty.dart';
import 'gradle_deep_reader.dart';
import 'gradle_structural_parser.dart';

/// Reads a project's Android build configuration.
///
/// Fast path only; `--deep` lives in `gradle_deep_reader.dart` and layers over
/// this result rather than replacing it, so a deep read that fails still leaves
/// the user with everything the structural parse found.
class AndroidInspector {
  const AndroidInspector({this.parser = const GradleStructuralParser()});

  final GradleStructuralParser parser;

  /// Relative path of the app module, which is where flavors are declared.
  static const String appModule = 'android/app';

  /// Locates the app build file, preferring Kotlin when both somehow exist.
  static ({GradleDsl dsl, String path})? locateBuildFile(String root) {
    for (final dsl in <GradleDsl>[GradleDsl.kotlin, GradleDsl.groovy]) {
      final relative = p.posix.join(appModule, dsl.buildFileName);
      if (File(p.join(root, relative)).existsSync()) {
        return (dsl: dsl, path: relative);
      }
    }
    return null;
  }

  /// Reads the Android build configuration.
  ///
  /// When [deep] is set, the structural parse is refined by asking Gradle for
  /// the resolved model. A failed deep read is reported and then ignored: the
  /// user is never left worse off than they would have been without `--deep`.
  Future<GradleParseResult> inspect(
    String root, {
    bool deep = false,
    ProcessRunner? runner,
    String? deepScriptPath,
  }) async {
    final fast = await _inspectFast(root);
    if (!deep || !fast.android.exists || runner == null) return fast;

    final scriptPath = deepScriptPath ?? GradleDeepReader.locateScript();
    if (scriptPath == null) {
      return GradleParseResult(
        android: fast.android,
        uncertainties: <Uncertainty>[
          ...fast.uncertainties,
          const Uncertainty(
            field: 'android',
            reason:
                'taxiway could not find its own Gradle init script '
                '(tool/gradle/taxiway_dump.gradle), so `--deep` was skipped.',
            remedy:
                'Reinstall taxiway. This is a packaging bug, not a problem '
                'with your project.',
            severity: UncertaintySeverity.defect,
          ),
        ],
      );
    }

    final result = await GradleDeepReader(
      runner: runner,
      scriptPath: scriptPath,
    ).read(root);

    final resolvedModel = result.android;
    if (!result.succeeded || resolvedModel == null) {
      return GradleParseResult(
        android: fast.android,
        uncertainties: <Uncertainty>[
          ...fast.uncertainties,
          Uncertainty(
            field: 'android',
            reason: '`--deep` could not run: ${result.failureReason}',
            remedy: result.failureRemedy ?? 'The fast parse was used instead.',
            source: fast.android.buildFilePath,
          ),
        ],
      );
    }

    final merged = GradleDeepReader.merge(fast.android, resolvedModel);
    final resolved = GradleDeepReader.resolvedBy(
      fast.uncertainties,
      merged,
    ).toSet();

    return GradleParseResult(
      android: merged,
      // Anything the deep read answered is no longer uncertain, and leaving it
      // in the report would tell the user to do something already done.
      uncertainties: fast.uncertainties
          .where((u) => !resolved.contains(u))
          .toList(),
    );
  }

  Future<GradleParseResult> _inspectFast(String root) async {
    final located = locateBuildFile(root);
    if (located == null) {
      final log = UncertaintyLog()
        ..defect(
          field: 'android',
          reason: 'no android/app/build.gradle or build.gradle.kts was found.',
          remedy: 'Run taxiway from the directory containing pubspec.yaml.',
        );
      return GradleParseResult(
        android: const AndroidModel.absent(),
        uncertainties: log.build(),
      );
    }

    final source = await File(p.join(root, located.path)).readAsString();
    final result = parser.parse(
      source,
      dsl: located.dsl,
      buildFilePath: located.path,
      sourceSets: readSourceSets(root),
    );

    return GradleParseResult(
      android: result.android,
      uncertainties: <Uncertainty>[
        ...result.uncertainties,
        ..._checkSourceSets(result.android),
      ],
    );
  }

  /// Directory names under `android/app/src/`.
  ///
  /// This is where per-flavor resources and `google-services.json` live, so a
  /// flavor with no source set is a real, silent gap.
  static List<String> readSourceSets(String root) {
    final dir = Directory(p.join(root, appModule, 'src'));
    if (!dir.existsSync()) return const <String>[];
    return dir
        .listSync()
        .whereType<Directory>()
        .map((d) => p.basename(d.path))
        .where(_isSourceSetName)
        .toList()
      ..sort();
  }

  /// Build output and editor metadata turn up under `src/` on real projects.
  /// Reporting them as source sets would be actively misleading.
  static bool _isSourceSetName(String name) =>
      name != 'build' && !name.startsWith('.');

  /// Flags flavors whose Firebase config is present for some flavors but not
  /// others — an asymmetry that builds fine and fails at runtime.
  List<Uncertainty> _checkSourceSets(AndroidModel android) {
    if (!android.hasFlavors) return const <Uncertainty>[];
    final withSourceSet = android.flavors.keys
        .where((f) => android.sourceSets.contains(f))
        .toSet();
    if (withSourceSet.isEmpty ||
        withSourceSet.length == android.flavors.length) {
      return const <Uncertainty>[];
    }
    final missing = android.flavors.keys.where(
      (f) => !android.sourceSets.contains(f),
    );
    return <Uncertainty>[
      Uncertainty(
        field: 'android.sourceSets',
        reason:
            'flavors ${missing.map((f) => '`$f`').join(', ')} have no '
            'directory under android/app/src/, but '
            '${withSourceSet.map((f) => '`$f`').join(', ')} do.',
        remedy:
            'If those flavors need their own google-services.json or '
            'resources, create the missing directories.',
        severity: UncertaintySeverity.defect,
        source: 'android/app/src',
      ),
    ];
  }
}
