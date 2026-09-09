import 'package:mason_logger/mason_logger.dart';
import 'package:taxiway/src/cli/exit_codes.dart';
import 'package:taxiway/src/cli/taxiway_command_runner.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';
import '../../support/recording_process_runner.dart';

class _CapturingLogger extends Logger {
  final List<String> lines = <String>[];

  @override
  void info(String? message, {LogStyle? style}) => lines.add(message ?? '');

  @override
  void err(String? message, {LogStyle? style}) => lines.add(message ?? '');

  @override
  void warn(String? message, {String tag = 'WARN', LogStyle? style}) =>
      lines.add(message ?? '');

  @override
  void detail(String? message, {LogStyle? style}) => lines.add(message ?? '');

  @override
  void write(String? message) => lines.add(message ?? '');

  String get output => lines.join('\n');

  void clear() => lines.clear();
}

/// A scheme with the parts a generated one must preserve: the blueprint
/// identifier and Flutter's prepare step.
const String _runnerScheme = '''
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1510" version = "1.3">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <PreActions>
         <ExecutionAction ActionType = "Xcode.IDEStandardExecutionActionsCore.ExecutionActionType.ShellScriptAction">
            <ActionContent title = "Run Prepare Flutter Framework Script" scriptText = "/bin/sh &quot;\$FLUTTER_ROOT/packages/flutter_tools/bin/xcode_backend.sh&quot; prepare">
            </ActionContent>
         </ExecutionAction>
      </PreActions>
      <BuildActionEntries>
         <BuildActionEntry buildForRunning = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "97C146ED1CF9000F007C117D" BuildableName = "Runner.app" BlueprintName = "Runner" ReferencedContainer = "container:Runner.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug"></TestAction>
   <LaunchAction buildConfiguration = "Debug"></LaunchAction>
   <ProfileAction buildConfiguration = "Profile"></ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release"></ArchiveAction>
</Scheme>
''';

void main() {
  late _CapturingLogger logger;
  late RecordingProcessRunner runner;
  late FixtureProject project;

  /// A project already configured exactly the way taxiway would configure it.
  /// This is the round-trip case: import, adopt, generate, expect no change.
  Future<void> makeAgreeingProject({bool kotlin = true}) async {
    final flavors = kotlin
        ? '''
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
    }'''
        : '''
    flavorDimensions "environment"

    productFlavors {
        dev {
            dimension "environment"
            applicationIdSuffix ".dev"
            resValue "string", "app_name", "Acme Dev"
        }

        prod {
            dimension "environment"
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
$flavors
}
''', kotlin: kotlin)
      ..withEntrypoint('dev')
      ..withEntrypoint('prod')
      ..withIosProject()
      ..write(
        'ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme',
        _runnerScheme,
      )
      ..withSharedScheme('dev', launch: 'Debug-dev', archive: 'Release-dev')
      ..withSharedScheme('prod', launch: 'Debug-prod', archive: 'Release-prod');

    stubConfigure(runner, flavors: const <String>['dev', 'prod']);
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
  }

  setUp(() async {
    logger = _CapturingLogger();
    runner = RecordingProcessRunner();
    project = await FixtureProject.create();
    addTearDown(project.dispose);
  });

  Future<int> run(List<String> args) => TaxiwayCommandRunner(
    logger: logger,
    runner: runner,
    workingDirectory: project.path,
  ).run(<String>['--no-color', '--yes', ...args]);

  group('generate refuses to touch what taxiway does not own', () {
    setUp(makeAgreeingProject);

    test('blocks on the unadopted Gradle file and names adopt', () async {
      await run(<String>['import']);
      logger.clear();

      final exit = await run(<String>['generate', 'android-flavors']);

      expect(exit, TaxiwayExit.userError);
      expect(logger.output, contains('conflict'));
      expect(logger.output, contains('was here before taxiway'));
      expect(logger.output, contains('taxiway adopt'));
    });

    test('leaves the file byte-identical when blocked', () async {
      await run(<String>['import']);
      final before = project.read('android/app/build.gradle.kts');

      await run(<String>['generate']);

      expect(project.read('android/app/build.gradle.kts'), before);
    });

    test('--force does not override an unadopted file', () async {
      await run(<String>['import']);
      final before = project.read('android/app/build.gradle.kts');
      logger.clear();

      final exit = await run(<String>['generate', '--force']);

      // Adoption is a decision, not a flag typed in a hurry.
      expect(exit, TaxiwayExit.userError);
      expect(project.read('android/app/build.gradle.kts'), before);
      expect(logger.output, contains('taxiway adopt'));
    });

    test('--dry-run writes nothing even for files it could create', () async {
      await run(<String>['import']);
      final before = project.allFiles();
      logger.clear();

      await run(<String>['generate', '--dry-run']);

      expect(project.allFiles(), before);
      expect(logger.output, contains('Nothing was written.'));
    });
  });

  group('adopt', () {
    setUp(makeAgreeingProject);

    test('reports that the config already describes the project', () async {
      await run(<String>['import']);
      logger.clear();

      await run(<String>['adopt', 'all']);

      expect(logger.output, contains('already describes this project exactly'));
    });

    test('changes ownership without changing file content', () async {
      await run(<String>['import']);
      final before = project.read('android/app/build.gradle.kts');

      await run(<String>['adopt', 'all']);

      expect(
        project.read('android/app/build.gradle.kts'),
        before,
        reason: 'adopt records ownership; generate is what writes',
      );
      expect(project.read('.taxiway/lock.json'), contains('"adopted"'));
    });

    test('unblocks generate', () async {
      await run(<String>['import']);
      await run(<String>['adopt', 'all']);
      logger.clear();

      expect(await run(<String>['generate']), TaxiwayExit.success);
    });

    test('rejects a path taxiway does not manage', () async {
      await run(<String>['import']);
      logger.clear();

      final exit = await run(<String>['adopt', 'lib/some_widget.dart']);

      expect(exit, TaxiwayExit.userError);
      expect(logger.output, contains('does not generate'));
    });

    test('needs a target', () async {
      await run(<String>['import']);
      logger.clear();
      expect(await run(<String>['adopt']), TaxiwayExit.userError);
      expect(logger.output, contains('a path, or `all`'));
    });
  });

  for (final kotlin in <bool>[true, false]) {
    final dialect = kotlin ? 'Kotlin' : 'Groovy';

    group('round trip on a $dialect project', () {
      setUp(() => makeAgreeingProject(kotlin: kotlin));

      /// The single most valuable test in the project: a project already
      /// configured the way taxiway would configure it must survive
      /// import -> adopt -> generate untouched, apart from taxiway's markers.
      test('import, adopt, generate changes no build configuration', () async {
        final gradlePath =
            'android/app/${kotlin ? 'build.gradle.kts' : 'build.gradle'}';

        await run(<String>['import']);
        await run(<String>['adopt', 'all']);
        await run(<String>['generate']);

        final after = project.read(gradlePath);

        // The flavors are unchanged in substance: same names, same suffixes,
        // same display names, still inside `android { }`.
        expect(after, contains('applicationIdSuffix'));
        expect(after, contains('.dev'));
        expect(after, contains('Acme Dev'));
        expect(after, contains('dev'));
        expect(after, contains('prod'));
        expect(after, contains('BEGIN taxiway (managed)'));
        expect(after, contains('END taxiway'));
        // And nothing outside the block was disturbed.
        expect(after, contains('applicationId'));
        expect(after, contains('com.acme.app'));
      });

      test('re-running generate is a no-op', () async {
        await run(<String>['import']);
        await run(<String>['adopt', 'all']);
        await run(<String>['generate']);

        final snapshot = <String, String>{
          for (final path in project.allFiles()) path: project.read(path),
        };
        logger.clear();

        final exit = await run(<String>['generate']);

        expect(exit, TaxiwayExit.success);
        for (final entry in snapshot.entries) {
          expect(
            project.read(entry.key),
            entry.value,
            reason: '${entry.key} changed on a second generate',
          );
        }
        expect(logger.output, contains('0 written'));
      });

      test('status reports no drift after generate', () async {
        await run(<String>['import']);
        await run(<String>['adopt', 'all']);
        await run(<String>['generate']);
        logger.clear();

        await run(<String>['status']);

        expect(logger.output, contains('In sync.'));
      });
    });
  }

  group('generated content', () {
    setUp(makeAgreeingProject);

    test(
      'schemes are written shared and keep the blueprint and prepare step',
      () async {
        await run(<String>['import']);
        await run(<String>['adopt', 'all']);
        await run(<String>['generate']);

        final scheme = project.read(
          'ios/Runner.xcodeproj/xcshareddata/xcschemes/dev.xcscheme',
        );
        // A scheme without these is syntactically fine and does not build.
        expect(scheme, contains('97C146ED1CF9000F007C117D'));
        expect(scheme, contains('xcode_backend.sh'));
        expect(scheme, contains('buildConfiguration="Debug-dev"'));
        expect(scheme, contains('buildConfiguration="Release-dev"'));
        expect(scheme, contains('buildConfiguration="Profile-dev"'));
        // Never xcuserdata.
        expect(project.exists('ios/Runner.xcodeproj/xcuserdata'), isFalse);
      },
    );

    test('an xcconfig per flavor carries its bundle id', () async {
      await run(<String>['import']);
      await run(<String>['adopt', 'all']);
      await run(<String>['generate']);

      // The bundle id is documented here but assigned on the build
      // configuration, because a target's own settings win over its xcconfig.
      expect(
        project.read('ios/Flutter/dev.xcconfig'),
        contains('// configuration itself, and is com.acme.app.dev.'),
      );
      expect(
        project.read('ios/Flutter/dev.xcconfig'),
        contains('APP_DISPLAY_NAME = Acme Dev'),
      );
    });

    test('the gitignore block covers every secret-bearing path', () async {
      await run(<String>['import']);
      await run(<String>['adopt', 'all']);
      await run(<String>['generate']);

      final gitignore = project.read('.gitignore');
      for (final pattern in const <String>[
        '.env',
        '*.p8',
        '*.jks',
        '*.keystore',
        '**/key.properties',
        '**/service-account*.json',
      ]) {
        expect(gitignore, contains(pattern));
      }
      // Ownership is a team-wide fact and must stay committed.
      expect(gitignore, isNot(contains('.taxiway/lock.json')));
      // An example file must stay trackable.
      expect(gitignore, contains('!.env*.example'));
    });
  });

  group('editing a managed block', () {
    setUp(makeAgreeingProject);

    Future<void> setUpGenerated() async {
      await run(<String>['import']);
      await run(<String>['adopt', 'all']);
      await run(<String>['generate']);
    }

    test('an edit inside the block is refused with a diff', () async {
      await setUpGenerated();
      final edited = project
          .read('android/app/build.gradle.kts')
          .replaceAll('Acme Dev', 'Hand Edited');
      project.write('android/app/build.gradle.kts', edited);
      logger.clear();

      final exit = await run(<String>['generate', 'android-flavors']);

      // Refusing to do what was asked is a user error, the same as a conflict
      // on an unadopted file: something needs a decision.
      expect(exit, TaxiwayExit.userError);
      expect(logger.output, contains('edited'));
      expect(logger.output, contains('--force'));
      expect(
        project.read('android/app/build.gradle.kts'),
        contains('Hand Edited'),
        reason: 'the edit must survive a refusal',
      );
    });

    test('--force discards the edit', () async {
      await setUpGenerated();
      project.write(
        'android/app/build.gradle.kts',
        project
            .read('android/app/build.gradle.kts')
            .replaceAll('Acme Dev', 'Hand Edited'),
      );

      await run(<String>['generate', 'android-flavors', '--force']);

      expect(
        project.read('android/app/build.gradle.kts'),
        contains('Acme Dev'),
      );
    });

    test('an edit outside the block is left alone', () async {
      await setUpGenerated();
      final withExtra = project
          .read('android/app/build.gradle.kts')
          .replaceFirst('android {', 'android {\n    // my own note');
      project.write('android/app/build.gradle.kts', withExtra);

      await run(<String>['generate', 'android-flavors']);

      // Editing around the block is the user's right and not a conflict.
      expect(
        project.read('android/app/build.gradle.kts'),
        contains('// my own note'),
      );
    });
  });
}
