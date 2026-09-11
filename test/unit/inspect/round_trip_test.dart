import 'package:shipway/src/core/config/config_loader.dart';
import 'package:shipway/src/core/model/model_diff.dart';
import 'package:shipway/src/core/model/project_comparison.dart';
import 'package:shipway/src/core/model/project_model.dart';
import 'package:shipway/src/inspect/config_from_project.dart';
import 'package:shipway/src/inspect/config_writer.dart';
import 'package:shipway/src/inspect/project_from_config.dart';
import 'package:shipway/src/inspect/project_inspector.dart';
import 'package:shipway/src/version.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';
import '../../support/recording_process_runner.dart';

/// Import fidelity: `projectFromConfig(configFromProject(read(p)))` must agree
/// with `read(p)`.
///
/// This is the headline gate. If a reader finds a value the config cannot
/// express, the round trip loses it and `shipway status` reports drift the
/// moment it is run — which is exactly how the missing `versionNameSuffix`
/// field was found.
void main() {
  late RecordingProcessRunner runner;

  setUp(() => runner = RecordingProcessRunner());

  Future<ProjectModel> read(FixtureProject project) => ProjectInspector(
    runner: runner,
    bridgeScriptPath: 'tool/ruby/xcodeproj_bridge.rb',
  ).readFromDisk(project.path);

  /// Reads, derives a config, renders and reparses it, rebuilds a model, and
  /// diffs it against what was read. Goes through YAML deliberately: a field
  /// the writer forgets to emit is just as lossy as one the model forgets.
  Future<ModelDiff> roundTrip(FixtureProject project) async {
    final actual = await read(project);
    final yaml = ConfigWriter.render(
      ConfigFromProject.build(actual),
      generatedBy: packageVersion,
      generatedAt: DateTime.utc(2026, 9, 9),
    );
    final expected = ProjectFromConfig.build(
      ConfigLoader.parse(yaml),
      root: project.path,
      gradleDsl: actual.android.gradleDsl!,
    );
    return compare(expected, actual);
  }

  Future<FixtureProject> flavoredProject({
    required bool kotlin,
    String versionNameSuffix = '-dev',
    String dimension = 'environment',
  }) async {
    final project = await FixtureProject.create();
    final flavors = kotlin
        ? '''
    productFlavors {
        create("dev") {
            dimension = "$dimension"
            applicationIdSuffix = ".dev"
            versionNameSuffix = "$versionNameSuffix"
            resValue("string", "app_name", "Acme Dev")
        }
        create("prod") {
            dimension = "$dimension"
            resValue("string", "app_name", "Acme")
        }
    }'''
        : '''
    productFlavors {
        dev {
            dimension "$dimension"
            applicationIdSuffix ".dev"
            versionNameSuffix "$versionNameSuffix"
            resValue "string", "app_name", "Acme Dev"
        }
        prod {
            dimension "$dimension"
            resValue "string", "app_name", "Acme"
        }
    }''';

    project
      ..withPubspec(name: 'acme_app')
      ..withGradle('''
android {
    defaultConfig {
        applicationId ${kotlin ? '= ' : ''}"com.acme.app"
    }
    flavorDimensions ${kotlin ? '+= ' : ''}"$dimension"
$flavors
}
''', kotlin: kotlin)
      ..withSourceSet('dev')
      ..withSourceSet('prod')
      ..withEntrypoint('dev')
      ..withEntrypoint('prod')
      ..withIosProject()
      ..withSharedScheme('dev', launch: 'Debug-dev', archive: 'Release-dev')
      ..withSharedScheme('prod', launch: 'Debug-prod', archive: 'Release-prod');

    stubBridge(
      runner,
      stubBridgeJson(
        configurations: <String, String>{
          'Debug': 'com.acme.app',
          'Release': 'com.acme.app',
          'Profile': 'com.acme.app',
          'Debug-dev': 'com.acme.app.dev',
          'Release-dev': 'com.acme.app.dev',
          'Profile-dev': 'com.acme.app.dev',
          'Debug-prod': 'com.acme.app',
          'Release-prod': 'com.acme.app',
          'Profile-prod': 'com.acme.app',
        },
      ),
    );
    return project;
  }

  for (final kotlin in <bool>[true, false]) {
    final dialect = kotlin ? 'Kotlin' : 'Groovy';

    group('$dialect DSL', () {
      test('a freshly imported project reports zero drift', () async {
        final project = await flavoredProject(kotlin: kotlin);
        addTearDown(project.dispose);

        final diff = await roundTrip(project);
        expect(
          diff.changes.map((c) => c.describe()),
          isEmpty,
          reason: 'import lost information the readers found',
        );
      });

      test('versionNameSuffix survives the round trip', () async {
        final project = await flavoredProject(
          kotlin: kotlin,
          versionNameSuffix: '-alpha',
        );
        addTearDown(project.dispose);

        final config = ConfigFromProject.build(await read(project));
        expect(
          config.apps['main']!.flavors['dev']!.versionNameSuffix,
          '-alpha',
        );
        expect((await roundTrip(project)).isEmpty, isTrue);
      });

      test('a non-default flavor dimension survives the round trip', () async {
        final project = await flavoredProject(
          kotlin: kotlin,
          dimension: 'tier',
        );
        addTearDown(project.dispose);

        final config = ConfigFromProject.build(await read(project));
        expect(config.apps['main']!.flavors['dev']!.dimension, 'tier');
        expect((await roundTrip(project)).isEmpty, isTrue);
      });
    });
  }

  group('the default dimension stays implicit', () {
    test(
      'is omitted from the config when it is the one shipway generates',
      () async {
        final project = await flavoredProject(kotlin: true);
        addTearDown(project.dispose);

        final config = ConfigFromProject.build(await read(project));
        // Writing `dimension: environment` on every flavor would be noise that
        // only restates the convention.
        expect(config.apps['main']!.flavors['dev']!.dimension, isNull);
      },
    );
  });

  group('drift is detected when the project moves', () {
    test('a flavor added to Gradle after import shows up as drift', () async {
      final project = await flavoredProject(kotlin: true);
      addTearDown(project.dispose);

      final actual = await read(project);
      final yaml = ConfigWriter.render(
        ConfigFromProject.build(actual),
        generatedBy: packageVersion,
        generatedAt: DateTime.utc(2026, 9, 9),
      );

      // Someone adds a flavor in Gradle without touching shipway.yaml.
      project.withGradle('''
android {
    defaultConfig {
        applicationId = "com.acme.app"
    }
    flavorDimensions += "environment"
    productFlavors {
        create("dev") {
            dimension = "environment"
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            resValue("string", "app_name", "Acme Dev")
        }
        create("prod") {
            dimension = "environment"
            resValue("string", "app_name", "Acme")
        }
        create("staging") {
            dimension = "environment"
            applicationIdSuffix = ".staging"
        }
    }
}
''');

      final diff = compare(
        ProjectFromConfig.build(ConfigLoader.parse(yaml), root: project.path),
        await read(project),
      );

      final change = diff.changes.firstWhere(
        (c) => c.path == 'android.flavors.staging',
      );
      expect(change.kind, ChangeKind.onlyInProject);
      expect(change.describe(), contains('not in shipway.yaml'));
    });

    test('a changed suffix shows both values', () async {
      final project = await flavoredProject(kotlin: true);
      addTearDown(project.dispose);

      final yaml = ConfigWriter.render(
        ConfigFromProject.build(await read(project)),
        generatedBy: packageVersion,
        generatedAt: DateTime.utc(2026, 9, 9),
      ).replaceAll('suffix: .dev', 'suffix: .development');

      final diff = compare(
        ProjectFromConfig.build(ConfigLoader.parse(yaml), root: project.path),
        await read(project),
      );

      final change = diff.changes.firstWhere(
        (c) => c.path == 'android.flavors.dev.applicationIdSuffix',
      );
      expect(change.kind, ChangeKind.different);
      expect(change.describe(), contains('.development'));
      expect(change.describe(), contains('.dev'));
    });
  });
}
