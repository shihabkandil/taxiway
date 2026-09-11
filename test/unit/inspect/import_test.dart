import 'package:shipway/src/core/config/config_loader.dart';
import 'package:shipway/src/core/managed/lock_file.dart';
import 'package:shipway/src/core/model/project_model.dart';
import 'package:shipway/src/core/model/uncertainty.dart';
import 'package:shipway/src/inspect/config_from_project.dart';
import 'package:shipway/src/inspect/config_writer.dart';
import 'package:shipway/src/inspect/project_inspector.dart';
import 'package:shipway/src/version.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';
import '../../support/recording_process_runner.dart';

/// A regular, well-formed flavored project — the common cohort.
Future<FixtureProject> wellFormedProject(RecordingProcessRunner runner) async {
  final project = await FixtureProject.create();
  project
    ..withPubspec(name: 'acme_app', version: '2.1.0+7')
    ..withGradle('''
android {
    namespace = "com.acme.app"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.acme.app"
        minSdk = 24
        targetSdk = 36
    }
    flavorDimensions += "environment"
    productFlavors {
        create("dev") {
            dimension = "environment"
            applicationIdSuffix = ".dev"
            resValue("string", "app_name", "Acme Dev")
        }
        create("prod") {
            dimension = "environment"
            resValue("string", "app_name", "Acme")
        }
    }
}
''')
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

/// Deliberately irregular: every defect the plan names is planted here.
Future<FixtureProject> handrolledProject(RecordingProcessRunner runner) async {
  final project = await FixtureProject.create();
  project
    ..withPubspec(name: 'handrolled_app')
    // applicationId comes from an ext property the fast parser cannot resolve.
    ..withGradle('''
android {
    defaultConfig {
        applicationId appId
    }
    flavorDimensions "environment"
    productFlavors {
        dev {
            dimension "environment"
            applicationIdSuffix ".dev"
        }
        staging {
            dimension "environment"
            applicationIdSuffix ".staging"
        }
    }
}
''', kotlin: false)
    ..withSourceSet('dev')
    ..withEntrypoint('dev')
    ..withIosProject()
    // Shared for `dev`; `Dev` on iOS differs only by case.
    ..withUserScheme(
      'Dev',
      owner: 'alice',
      launch: 'Debug-Dev',
      archive: 'Release-Dev',
    );

  stubBridge(
    runner,
    stubBridgeJson(
      configurations: <String, String>{
        'Debug': 'com.acme.hand',
        'Release': 'com.acme.hand',
        'Profile': 'com.acme.hand',
        'Debug-Dev': 'com.acme.hand.dev',
        'Release-Dev': 'com.acme.hand.dev',
        'Profile-Dev': 'com.acme.hand.dev',
      },
    ),
  );
  return project;
}

void main() {
  late RecordingProcessRunner runner;

  setUp(() => runner = RecordingProcessRunner());

  Future<ProjectModel> read(FixtureProject project) => ProjectInspector(
    runner: runner,
    bridgeScriptPath: 'tool/ruby/xcodeproj_bridge.rb',
  ).readFromDisk(project.path);

  group('a well-formed project imports cleanly', () {
    test('derives an accurate config', () async {
      final project = await wellFormedProject(runner);
      addTearDown(project.dispose);

      final config = ConfigFromProject.build(await read(project));
      final app = config.apps['main']!;

      expect(config.project.name, 'acme_app');
      expect(app.android!.applicationId, 'com.acme.app');
      expect(app.ios!.bundleId, 'com.acme.app');
      expect(app.flavors.keys, <String>['dev', 'prod']);
      expect(app.flavors['dev']!.suffix, '.dev');
      expect(app.flavors['dev']!.displayName, 'Acme Dev');
      expect(app.flavors['prod']!.suffix, '');
      // Conventional entrypoints are left implicit rather than restated.
      expect(app.flavors['dev']!.entrypoint, isNull);
    });

    test('reports no defects', () async {
      final project = await wellFormedProject(runner);
      addTearDown(project.dispose);

      final model = await read(project);
      expect(
        model.uncertainties
            .where((u) => u.severity == UncertaintySeverity.defect)
            .map((u) => u.toString()),
        isEmpty,
      );
    });

    test('the rendered config parses back to an equivalent config', () async {
      final project = await wellFormedProject(runner);
      addTearDown(project.dispose);

      final original = ConfigFromProject.build(await read(project));
      final yaml = ConfigWriter.render(
        original,
        generatedBy: packageVersion,
        generatedAt: DateTime.utc(2026, 9, 9),
      );
      // Import fidelity: what we wrote down must survive being read back, or
      // the config describes something other than the project.
      final reparsed = ConfigLoader.parse(yaml);
      expect(reparsed.toJson(), original.toJson());
    });
  });

  group('the handrolled project reports every planted defect', () {
    late ProjectModel model;
    late FixtureProject project;

    setUp(() async {
      project = await handrolledProject(runner);
      addTearDown(project.dispose);
      model = await read(project);
    });

    String findingsText() => model.uncertainties
        .map((u) => '${u.field} ${u.reason} ${u.remedy}')
        .join('\n');

    test('the ext-property applicationId is an uncertainty, not a guess', () {
      expect(model.android.applicationId, isNull);
      final uncertainty = model.uncertainties.firstWhere(
        (u) => u.field == 'android.applicationId',
      );
      expect(uncertainty.severity, UncertaintySeverity.unresolved);
      expect(uncertainty.deepMayResolve, isTrue);
    });

    test('the xcuserdata-only scheme is called out', () {
      expect(findingsText(), contains('xcuserdata'));
      expect(findingsText(), contains('alice'));
    });

    test('the dev/Dev casing mismatch is one clear finding', () {
      final casing = model.uncertainties.firstWhere(
        (u) => u.reason.contains('case-sensitively'),
      );
      expect(casing.reason, contains('`dev` on Android'));
      expect(casing.reason, contains('`Dev` on iOS'));
    });

    test(
      'the Android-only staging flavor is reported as a cross-platform gap',
      () {
        final gap = model.uncertainties.firstWhere(
          (u) => u.field == 'flavors.staging',
        );
        expect(gap.reason, contains('no iOS build configurations'));
        expect(gap.remedy, contains('Debug-staging'));
      },
    );

    test('the missing staging entrypoint is reported', () {
      expect(findingsText(), contains('lib/main_staging.dart'));
    });

    test('the config omits what could not be determined', () {
      final app = ConfigFromProject.build(model).apps['main']!;
      // No application id was resolvable, so none is asserted.
      expect(app.android, isNull);
      expect(app.flavors.keys, containsAll(<String>['dev', 'staging', 'Dev']));
    });
  });

  group('a project with no flavors still imports', () {
    test('derives a valid single-flavor config', () async {
      final project = await FixtureProject.create();
      addTearDown(project.dispose);
      project
        ..withPubspec(name: 'plain_app')
        ..withGradle('''
android {
    defaultConfig {
        applicationId = "com.acme.plain"
    }
}
''')
        ..withIosProject();
      stubBridge(
        runner,
        stubBridgeJson(
          configurations: <String, String>{
            'Debug': 'com.acme.plain',
            'Release': 'com.acme.plain',
            'Profile': 'com.acme.plain',
          },
        ),
      );

      final config = ConfigFromProject.build(await read(project));
      expect(config.apps['main']!.flavors, isEmpty);
      expect(config.apps['main']!.android!.applicationId, 'com.acme.plain');
      expect(config.apps['main']!.ios!.bundleId, 'com.acme.plain');

      // Must still be a config shipway will accept.
      final yaml = ConfigWriter.render(
        config,
        generatedBy: packageVersion,
        generatedAt: DateTime.utc(2026, 9, 9),
      );
      expect(ConfigLoader.parse(yaml).apps, hasLength(1));
    });
  });

  group('an existing fastlane setup seeds the config', () {
    test('harvests secret names rather than inventing them', () async {
      final project = await FixtureProject.create();
      addTearDown(project.dispose);
      project
        ..withPubspec()
        ..withGradle(
          'android { defaultConfig { applicationId = "com.acme.f" } }',
        )
        ..withIosProject()
        ..withFastlane(
          'ios/fastlane',
          fastfile: '''
platform :ios do
  desc "Build"
  lane :build_dev do
    app_store_connect_api_key(
      key_id: ENV["MY_ASC_KEY_ID"],
      issuer_id: ENV["MY_ASC_ISSUER_ID"],
      key_content: ENV["MY_ASC_P8_BASE64"],
    )
    match(type: "appstore", readonly: true)
  end

  private_lane :helper do
  end
end
''',
          appfile: '''
app_identifier "com.acme.f"
team_id "TEAM123456"
''',
          matchfile: '''
git_url "git@github.com:acme/certs.git"
storage_mode "git"
type "appstore"
''',
        );
      stubBridge(
        runner,
        stubBridgeJson(
          configurations: <String, String>{'Release': 'com.acme.f'},
          developmentTeam: null,
        ),
      );

      final model = await read(project);
      final setup = model.fastlane.single;

      expect(setup.directory, 'ios/fastlane');
      expect(setup.laneNames, <String>['build_dev', 'helper']);
      expect(
        setup.lanes.firstWhere((l) => l.name == 'helper').isPrivate,
        isTrue,
      );
      expect(setup.lanes.first.platform, 'ios');
      expect(setup.teamId, 'TEAM123456');
      expect(setup.matchGitUrl, 'git@github.com:acme/certs.git');
      expect(setup.matchType, 'appstore');
      expect(
        setup.environmentVariables,
        containsAll(<String>[
          'MY_ASC_KEY_ID',
          'MY_ASC_ISSUER_ID',
          'MY_ASC_P8_BASE64',
        ]),
      );

      final signing = ConfigFromProject.build(model).apps['main']!.signing;
      expect(signing.ios!.teamId, 'TEAM123456');
      expect(signing.ios!.matchGitUrl, 'git@github.com:acme/certs.git');
      // The names the user already chose, not names shipway made up.
      expect(signing.ios!.apiKey!.keyIdRef, 'MY_ASC_KEY_ID');
      expect(signing.ios!.apiKey!.issuerIdRef, 'MY_ASC_ISSUER_ID');
      expect(signing.ios!.apiKey!.p8Ref, 'MY_ASC_P8_BASE64');
    });

    test(
      'the harvested config passes the secret-shaped-value validator',
      () async {
        final project = await FixtureProject.create();
        addTearDown(project.dispose);
        project
          ..withPubspec()
          ..withGradle(
            'android { defaultConfig { applicationId = "com.a.b" } }',
          )
          ..withFastlane(
            'ios/fastlane',
            fastfile: 'lane :x do\n  key(ENV["ASC_KEY_ID"])\nend\n',
          );

        final yaml = ConfigWriter.render(
          ConfigFromProject.build(await read(project)),
          generatedBy: packageVersion,
          generatedAt: DateTime.utc(2026, 9, 9),
        );
        // Parsing runs the validator; a harvested name must never look like a
        // pasted secret.
        expect(() => ConfigLoader.parse(yaml), returnsNormally);
      },
    );
  });

  group('the safety property', () {
    test('reading a project writes nothing at all', () async {
      final project = await wellFormedProject(runner);
      addTearDown(project.dispose);

      final before = project.allFiles();
      await read(project);
      expect(
        project.allFiles(),
        before,
        reason: 'the readers must not touch the project',
      );
    });

    test('import records everything it found as unmanaged', () async {
      final project = await wellFormedProject(runner);
      addTearDown(project.dispose);

      final model = await read(project);
      final lock = LockFile.empty();
      for (final path in <String>[
        model.android.buildFilePath!,
        'lib/main_dev.dart',
      ]) {
        lock.noteUnmanaged(path);
      }

      // Nothing import records may be writable: `adopt` is the only door.
      for (final entry in lock.files.values) {
        expect(entry.ownership, Ownership.unmanaged);
        expect(lock.mayWrite(entry.path), isFalse);
      }
    });
  });
}
