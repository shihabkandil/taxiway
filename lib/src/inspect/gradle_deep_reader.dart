import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/io/process_runner.dart';
import '../core/model/android_model.dart';
import '../core/model/uncertainty.dart';

/// What a deep read produced.
class DeepReadResult {
  const DeepReadResult({
    required this.android,
    required this.succeeded,
    this.failureReason,
    this.failureRemedy,
  });

  /// Null when the deep read did not run or failed.
  final AndroidModel? android;

  final bool succeeded;

  /// Why the deep read did not produce a model.
  final String? failureReason;

  final String? failureRemedy;
}

/// Asks Gradle for the resolved Android build model.
///
/// The authoritative path. It handles arbitrary dynamic configuration — `ext`
/// properties, flavors built in loops, `apply from:` — because it reads the
/// model after Gradle has evaluated all of it.
///
/// It costs 10-30 seconds and needs a project that currently configures, so it
/// is opt-in via `--deep` and always degrades to the fast parse rather than
/// failing the command.
class GradleDeepReader {
  const GradleDeepReader({required this.runner, required this.scriptPath});

  final ProcessRunner runner;

  /// Absolute path to the shipped init script.
  final String scriptPath;

  static const String beginMarker = '<<<SHIPWAY_JSON_BEGIN>>>';
  static const String endMarker = '<<<SHIPWAY_JSON_END>>>';

  /// Gradle configuration is slow, and a hung daemon must not hang shipway.
  static const Duration timeout = Duration(minutes: 3);

  /// Locates the init script the same way the Ruby bridge is located.
  static String? locateScript({String? packageRoot}) {
    final candidates = <String>[
      if (packageRoot != null)
        p.join(packageRoot, 'tool/gradle/shipway_dump.gradle'),
      p.join(Directory.current.path, 'tool/gradle/shipway_dump.gradle'),
      p.join(
        p.dirname(p.dirname(Platform.script.toFilePath())),
        'tool/gradle/shipway_dump.gradle',
      ),
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return p.normalize(candidate);
    }
    return null;
  }

  /// Runs the deep read against the project at [root].
  Future<DeepReadResult> read(String root) async {
    final wrapper = _gradlewPath(root);
    if (wrapper == null) {
      return const DeepReadResult(
        android: null,
        succeeded: false,
        failureReason: 'no Gradle wrapper was found at android/gradlew.',
        failureRemedy:
            'Run `flutter build apk --config-only` once to generate '
            'it, then re-run with `--deep`.',
      );
    }

    final result = await runner
        .run(wrapper, <String>[
          '--init-script',
          scriptPath,
          ':app:shipwayDumpVariants',
          '--quiet',
          // A deep read must not leave a daemon running against a project it
          // only meant to look at.
          //
          // Not `--offline`: a Flutter Android build resolves plugins from the
          // network, and forcing offline turns a working project into a failed
          // deep read for anyone without a fully warm cache.
          '--no-daemon',
        ], workingDirectory: p.join(root, 'android'))
        .timeout(
          timeout,
          onTimeout: () => ProcessResultLite(
            executable: wrapper,
            arguments: const <String>[],
            exitCode: 124,
            stdout: '',
            stderr:
                'Gradle did not finish within '
                '${timeout.inMinutes} minutes.',
          ),
        );

    final json = extractJson(result.output);
    if (json == null) {
      return DeepReadResult(
        android: null,
        succeeded: false,
        failureReason: _summarise(result),
        failureRemedy:
            'The fast parse was used instead. Fix the Gradle build '
            'and re-run with `--deep` to resolve the values above.',
      );
    }

    return DeepReadResult(android: _toModel(json), succeeded: true);
  }

  /// Pulls the delimited JSON out of Gradle's noisy output.
  ///
  /// Gradle prints daemon notices and deprecation warnings that `--quiet` does
  /// not reliably suppress, so the payload is fenced rather than assumed to be
  /// the whole of stdout.
  static Map<String, dynamic>? extractJson(String output) {
    final begin = output.indexOf(beginMarker);
    final end = output.indexOf(endMarker);
    if (begin == -1 || end == -1 || end < begin) return null;
    final body = output.substring(begin + beginMarker.length, end).trim();
    if (body.isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// Merges a deep result over a fast one.
  ///
  /// The deep read wins wherever it has an answer, but never erases something
  /// the fast parse found and it did not: a failed or partial deep read must
  /// leave the user no worse off than not passing `--deep`.
  static AndroidModel merge(AndroidModel fast, AndroidModel deep) {
    final flavors = <String, AndroidFlavor>{...fast.flavors};
    for (final entry in deep.flavors.entries) {
      final existing = flavors[entry.key];
      final resolved = entry.value;
      flavors[entry.key] = AndroidFlavor(
        name: entry.key,
        dimension: resolved.dimension ?? existing?.dimension,
        applicationId: resolved.applicationId ?? existing?.applicationId,
        applicationIdSuffix:
            resolved.applicationIdSuffix ?? existing?.applicationIdSuffix,
        versionNameSuffix:
            resolved.versionNameSuffix ?? existing?.versionNameSuffix,
        signingConfig: resolved.signingConfig ?? existing?.signingConfig,
        resValues: resolved.resValues.isNotEmpty
            ? resolved.resValues
            : (existing?.resValues ?? const <String, String>{}),
        manifestPlaceholders:
            existing?.manifestPlaceholders ?? const <String, String>{},
      );
    }

    return AndroidModel(
      // The DSL and build file are facts about the file on disk, which only the
      // fast path looked at.
      gradleDsl: fast.gradleDsl,
      buildFilePath: fast.buildFilePath,
      applicationId: deep.applicationId ?? fast.applicationId,
      namespace: deep.namespace ?? fast.namespace,
      compileSdk: deep.compileSdk ?? fast.compileSdk,
      minSdk: deep.minSdk ?? fast.minSdk,
      targetSdk: deep.targetSdk ?? fast.targetSdk,
      flavorDimensions: deep.flavorDimensions.isNotEmpty
          ? deep.flavorDimensions
          : fast.flavorDimensions,
      flavors: flavors,
      buildTypes: deep.buildTypes.isNotEmpty
          ? deep.buildTypes
          : fast.buildTypes,
      signingConfigs: deep.signingConfigs.isNotEmpty
          ? deep.signingConfigs
          : fast.signingConfigs,
      // Source sets come from the filesystem; Gradle reports every declared
      // set including ones with no directory, which is not what we mean here.
      sourceSets: fast.sourceSets,
    );
  }

  /// Uncertainties the deep read resolved, so import can say so rather than
  /// silently dropping them.
  static List<Uncertainty> resolvedBy(
    List<Uncertainty> fastUncertainties,
    AndroidModel merged,
  ) => fastUncertainties.where((u) {
    if (!u.deepMayResolve) return false;
    return _isNowKnown(u.field, merged);
  }).toList();

  static bool _isNowKnown(String field, AndroidModel model) {
    if (field == 'android.applicationId') return model.applicationId != null;
    if (field == 'android.flavorDimensions') {
      return model.flavorDimensions.isNotEmpty;
    }
    final flavorMatch = RegExp(
      r'^android\.flavors\.([^.]+)\.(.+)$',
    ).firstMatch(field);
    if (flavorMatch != null) {
      final flavor = model.flavors[flavorMatch.group(1)];
      if (flavor == null) return false;
      return switch (flavorMatch.group(2)) {
        'applicationId' => flavor.applicationId != null,
        'applicationIdSuffix' => flavor.applicationIdSuffix != null,
        'versionNameSuffix' => flavor.versionNameSuffix != null,
        'dimension' => flavor.dimension != null,
        _ => false,
      };
    }
    if (field == 'android.productFlavors') return model.flavors.isNotEmpty;
    return false;
  }

  static AndroidModel _toModel(Map<String, dynamic> json) {
    final flavors = <String, AndroidFlavor>{};
    for (final raw
        in (json['productFlavors'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>()) {
      final name = raw['name'] as String?;
      if (name == null) continue;
      flavors[name] = AndroidFlavor(
        name: name,
        dimension: raw['dimension'] as String?,
        applicationId: raw['applicationId'] as String?,
        applicationIdSuffix: raw['applicationIdSuffix'] as String?,
        versionNameSuffix: raw['versionNameSuffix'] as String?,
        signingConfig: raw['signingConfig'] as String?,
        resValues:
            (raw['resValues'] as Map<String, dynamic>? ??
                    const <String, dynamic>{})
                .map((k, v) => MapEntry(k, v.toString())),
      );
    }

    final signingConfigs = <String, AndroidSigningConfigDeclaration>{};
    for (final raw
        in (json['signingConfigs'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>()) {
      final name = raw['name'] as String?;
      if (name == null) continue;
      signingConfigs[name] = AndroidSigningConfigDeclaration(
        name: name,
        storeFile: raw['storeFile'] as String?,
        keyAlias: raw['keyAlias'] as String?,
        // Gradle reports the resolved value, so how it got there is no longer
        // visible or relevant.
        readsFromProperties: false,
      );
    }

    return AndroidModel(
      gradleDsl: null,
      applicationId: json['applicationId'] as String?,
      namespace: json['namespace'] as String?,
      compileSdk: (json['compileSdk'] as num?)?.toInt(),
      minSdk: (json['minSdk'] as num?)?.toInt(),
      targetSdk: (json['targetSdk'] as num?)?.toInt(),
      flavorDimensions: (json['flavorDimensions'] as List<dynamic>? ?? const [])
          .map((d) => d.toString())
          .toList(),
      flavors: flavors,
      buildTypes: (json['buildTypes'] as List<dynamic>? ?? const [])
          .map((b) => b.toString())
          .toList(),
      signingConfigs: signingConfigs,
    );
  }

  static String? _gradlewPath(String root) {
    final name = Platform.isWindows ? 'gradlew.bat' : 'gradlew';
    final wrapper = File(p.join(root, 'android', name));
    if (!wrapper.existsSync()) return null;
    // Gradle must be invoked from android/, so the wrapper is referenced
    // relatively; an absolute path works too but reads worse in --verbose.
    return p.join('.', name);
  }

  static String _summarise(ProcessResultLite result) {
    final output = result.output.trim();
    if (output.isEmpty) return 'Gradle exited with ${result.exitCode}.';
    final lines = output.split('\n').map((l) => l.trim()).toList();

    // Prefer a line that names the actual cause. Gradle's own `FAILURE: Build
    // failed with an exception.` banner is always present and never says
    // anything, so matching it first would throw away the useful line.
    const specific = <String>[
      'Unsupported class file',
      'Could not',
      'error:',
      'No such file',
      'Plugin ',
      'Unable to',
      'java.lang',
    ];
    for (final line in lines) {
      if (specific.any(line.contains)) return line;
    }
    for (final line in lines) {
      if (line.startsWith('FAILURE')) return line;
    }
    return lines.first;
  }
}
