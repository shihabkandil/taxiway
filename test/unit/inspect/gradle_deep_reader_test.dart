import 'dart:convert';

import 'package:shipway/src/core/model/android_model.dart';
import 'package:shipway/src/core/model/uncertainty.dart';
import 'package:shipway/src/inspect/android_inspector.dart';
import 'package:shipway/src/inspect/gradle_deep_reader.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';
import '../../support/recording_process_runner.dart';

/// Wraps a payload the way the init script prints it, fenced and surrounded by
/// the daemon noise `--quiet` does not suppress.
String gradleOutput(Map<String, Object?> payload, {String noise = ''}) =>
    '''
$noise
${GradleDeepReader.beginMarker}
${jsonEncode(payload)}
${GradleDeepReader.endMarker}
''';

/// The resolved model for a project whose applicationId comes from an `ext`
/// property — the case the fast parser must flag and `--deep` must answer.
Map<String, Object?> resolvedPayload() => <String, Object?>{
  'ok': true,
  'schema': 1,
  'applicationId': 'com.acme.resolved',
  'namespace': 'com.acme.resolved',
  'compileSdk': 36,
  'minSdk': 24,
  'targetSdk': 36,
  'flavorDimensions': <String>['environment'],
  'productFlavors': <Map<String, Object?>>[
    <String, Object?>{
      'name': 'dev',
      'dimension': 'environment',
      'applicationIdSuffix': '.dev',
      'versionNameSuffix': '-dev',
      'resValues': <String, String>{'app_name': 'Acme Dev'},
    },
    <String, Object?>{
      'name': 'prod',
      'dimension': 'environment',
      'resValues': <String, String>{'app_name': 'Acme'},
    },
  ],
  'buildTypes': <String>['debug', 'release'],
  'signingConfigs': <Map<String, Object?>>[
    <String, Object?>{'name': 'release', 'keyAlias': 'upload'},
  ],
};

void main() {
  late RecordingProcessRunner runner;
  late FixtureProject project;

  setUp(() async {
    runner = RecordingProcessRunner();
    project = await FixtureProject.create();
    addTearDown(project.dispose);

    // An ext-property applicationId, and a flavor built in a loop: both are
    // invisible to the fast parser and both are resolved by Gradle.
    project
      ..withPubspec()
      ..withGradle('''
android {
    defaultConfig {
        applicationId = appId
    }
    flavorDimensions += "environment"
    productFlavors {
        listOf("dev", "prod").forEach { name ->
            create(name) { dimension = "environment" }
        }
    }
}
''')
      ..write('android/gradlew', '#!/bin/sh\n');
  });

  Future<GradleParseResultLike> inspect({required bool deep}) async {
    final result = await const AndroidInspector().inspect(
      project.path,
      deep: deep,
      runner: runner,
      deepScriptPath: 'tool/gradle/shipway_dump.gradle',
    );
    return (android: result.android, uncertainties: result.uncertainties);
  }

  group('the fast path alone', () {
    test('cannot resolve the ext property and says so', () async {
      final result = await inspect(deep: false);
      expect(result.android.applicationId, isNull);
      expect(
        result.uncertainties.map((u) => u.field),
        contains('android.applicationId'),
      );
      expect(
        runner.invocations,
        isEmpty,
        reason: 'no Gradle run without --deep',
      );
    });
  });

  group('--deep resolves what the fast path could not', () {
    setUp(() {
      runner.stub(
        'shipwayDumpVariants',
        stdout: gradleOutput(
          resolvedPayload(),
          noise:
              'Daemon will be stopped at the end of the build\n'
              'Note: Some input files use deprecated API.',
        ),
      );
    });

    test('the ext-property applicationId is now known', () async {
      final result = await inspect(deep: true);
      expect(result.android.applicationId, 'com.acme.resolved');
    });

    test('the uncertainty is removed rather than left telling the user to '
        'do something already done', () async {
      final result = await inspect(deep: true);
      expect(
        result.uncertainties.map((u) => u.field),
        isNot(contains('android.applicationId')),
      );
    });

    test(
      'flavors created in a loop are recovered with their suffixes',
      () async {
        final result = await inspect(deep: true);
        expect(
          result.android.flavors.keys,
          containsAll(<String>['dev', 'prod']),
        );
        expect(result.android.flavors['dev']!.applicationIdSuffix, '.dev');
        expect(result.android.flavors['dev']!.versionNameSuffix, '-dev');
        expect(
          result.android.flavors['dev']!.resValues['app_name'],
          'Acme Dev',
        );
      },
    );

    test('the DSL and build file still come from the file on disk', () async {
      final result = await inspect(deep: true);
      // Gradle does not report which dialect the build file is written in.
      expect(result.android.gradleDsl, GradleDsl.kotlin);
      expect(result.android.buildFilePath, 'android/app/build.gradle.kts');
    });

    test('invokes the wrapper from android/ with the init script', () async {
      await inspect(deep: true);
      final invocation = runner.invocation('shipwayDumpVariants');
      expect(invocation.executable, './gradlew');
      expect(invocation.workingDirectory, endsWith('/android'));
      expect(
        invocation.arguments,
        containsAllInOrder(<String>[
          '--init-script',
          'tool/gradle/shipway_dump.gradle',
          ':app:shipwayDumpVariants',
        ]),
      );
      // A read must not leave a daemon behind.
      expect(invocation.arguments, contains('--no-daemon'));
      // Not --offline: a Flutter Android build resolves plugins from the
      // network, and forcing offline breaks projects with a cold cache.
      expect(invocation.arguments, isNot(contains('--offline')));
    });
  });

  group('a failed deep read leaves the user no worse off', () {
    test('falls back to the fast parse and explains why', () async {
      runner.stub(
        'shipwayDumpVariants',
        exitCode: 1,
        stdout:
            'FAILURE: Build failed with an exception.\n'
            'Unsupported class file major version 62',
      );

      final result = await inspect(deep: true);
      // Everything the fast parse found survives.
      expect(result.android.gradleDsl, GradleDsl.kotlin);
      expect(result.android.flavorDimensions, <String>['environment']);
      // And the original uncertainty is still reported, not swallowed.
      expect(
        result.uncertainties.map((u) => u.field),
        contains('android.applicationId'),
      );
      final failure = result.uncertainties.firstWhere(
        (u) => u.reason.contains('could not run'),
      );
      expect(failure.reason, contains('Unsupported class file'));
    });

    test('a missing Gradle wrapper is reported with a next step', () async {
      final bare = await FixtureProject.create();
      addTearDown(bare.dispose);
      bare
        ..withPubspec()
        ..withGradle('android { defaultConfig { applicationId = x } }');

      final result = await const AndroidInspector().inspect(
        bare.path,
        deep: true,
        runner: runner,
        deepScriptPath: 'tool/gradle/shipway_dump.gradle',
      );
      final failure = result.uncertainties.firstWhere(
        (u) => u.reason.contains('could not run'),
      );
      expect(failure.reason, contains('gradlew'));
      expect(failure.remedy, contains('--config-only'));
    });

    test('output with no JSON fence is a failure, not a bad parse', () async {
      runner.stub('shipwayDumpVariants', stdout: 'BUILD SUCCESSFUL in 3s');
      final result = await inspect(deep: true);
      expect(result.android.applicationId, isNull);
      expect(
        result.uncertainties.any((u) => u.reason.contains('could not run')),
        isTrue,
      );
    });
  });

  group('extractJson', () {
    test('finds the payload among daemon noise', () {
      final json = GradleDeepReader.extractJson(
        gradleOutput(<String, Object?>{
          'ok': true,
          'applicationId': 'com.x',
        }, noise: 'Starting a Gradle Daemon\nwarning: something'),
      );
      expect(json!['applicationId'], 'com.x');
    });

    test('returns null when the fence is absent or malformed', () {
      expect(GradleDeepReader.extractJson('BUILD SUCCESSFUL'), isNull);
      expect(
        GradleDeepReader.extractJson(
          '${GradleDeepReader.beginMarker}\nnot json\n'
          '${GradleDeepReader.endMarker}',
        ),
        isNull,
      );
      expect(
        GradleDeepReader.extractJson(
          '${GradleDeepReader.endMarker}\n{}\n${GradleDeepReader.beginMarker}',
        ),
        isNull,
      );
    });
  });

  group('merge', () {
    test(
      'the deep read wins but never erases what only the fast parse knew',
      () {
        const fast = AndroidModel(
          gradleDsl: GradleDsl.groovy,
          buildFilePath: 'android/app/build.gradle',
          applicationId: null,
          sourceSets: <String>['dev', 'main'],
          flavors: <String, AndroidFlavor>{
            'dev': AndroidFlavor(
              name: 'dev',
              manifestPlaceholders: <String, String>{'KEY': 'value'},
            ),
          },
        );
        const deep = AndroidModel(
          gradleDsl: null,
          applicationId: 'com.acme.resolved',
          flavors: <String, AndroidFlavor>{
            'dev': AndroidFlavor(name: 'dev', applicationIdSuffix: '.dev'),
          },
        );

        final merged = GradleDeepReader.merge(fast, deep);
        expect(merged.applicationId, 'com.acme.resolved');
        expect(merged.gradleDsl, GradleDsl.groovy);
        expect(merged.buildFilePath, 'android/app/build.gradle');
        expect(merged.flavors['dev']!.applicationIdSuffix, '.dev');
        // Source sets are a filesystem fact Gradle does not report the same way.
        expect(merged.sourceSets, <String>['dev', 'main']);
        expect(merged.flavors['dev']!.manifestPlaceholders, <String, String>{
          'KEY': 'value',
        });
      },
    );
  });

  group('resolvedBy', () {
    test('only counts uncertainties the merged model can now answer', () {
      const uncertainties = <Uncertainty>[
        Uncertainty(
          field: 'android.applicationId',
          reason: 'r',
          remedy: 'Re-run with `--deep`.',
        ),
        Uncertainty(
          field: 'android.flavors.dev.applicationIdSuffix',
          reason: 'r',
          remedy: 'Re-run with `--deep`.',
        ),
        Uncertainty(
          field: 'ios.schemes.dev',
          reason: 'r',
          remedy: 'Tick Shared in Xcode.',
        ),
      ];
      const merged = AndroidModel(
        gradleDsl: GradleDsl.kotlin,
        applicationId: 'com.acme.resolved',
      );

      final resolved = GradleDeepReader.resolvedBy(uncertainties, merged);
      expect(resolved.map((u) => u.field), <String>['android.applicationId']);
    });
  });
}

/// Shape of the inspector's result, named so the test reads clearly.
typedef GradleParseResultLike = ({
  AndroidModel android,
  List<Uncertainty> uncertainties,
});
