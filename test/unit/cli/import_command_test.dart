import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:taxiway/src/cli/exit_codes.dart';
import 'package:taxiway/src/cli/taxiway_command_runner.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';
import '../../support/recording_process_runner.dart';

/// Captures printed output; prompts always answer yes so `init` is testable
/// without a terminal.
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

  @override
  Progress progress(String message, {ProgressOptions? options}) {
    lines.add(message);
    return super.progress(message, options: options);
  }

  String get output => lines.join('\n');
}

void main() {
  late _CapturingLogger logger;
  late RecordingProcessRunner runner;
  late FixtureProject project;

  setUp(() async {
    logger = _CapturingLogger();
    runner = RecordingProcessRunner();
    project = await FixtureProject.create();
    addTearDown(project.dispose);

    project
      ..withPubspec(name: 'acme_app')
      ..withGradle('''
android {
    defaultConfig {
        applicationId = "com.acme.app"
    }
    flavorDimensions += "environment"
    productFlavors {
        create("dev") {
            dimension = "environment"
            applicationIdSuffix = ".dev"
        }
        create("prod") { dimension = "environment" }
    }
}
''')
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
  });

  Future<int> run(List<String> args) => TaxiwayCommandRunner(
    logger: logger,
    runner: runner,
    workingDirectory: project.path,
  ).run(<String>['--no-color', ...args]);

  group('taxiway import', () {
    test('writes exactly one file and says so', () async {
      final before = project.allFiles();
      expect(await run(<String>['import']), TaxiwayExit.success);

      final after = project.allFiles();
      final added = after.toSet().difference(before.toSet());

      // The safety property, asserted directly: import may add taxiway.yaml and
      // the lockfile, and nothing else.
      expect(added, <String>{'taxiway.yaml', '.taxiway/lock.json'});
      for (final path in before) {
        expect(project.read(path), isNotNull, reason: '$path still readable');
      }
      expect(logger.output, contains('No project files were modified.'));
    });

    test('--dry-run writes nothing at all', () async {
      final before = project.allFiles();
      expect(await run(<String>['import', '--dry-run']), TaxiwayExit.success);
      expect(project.allFiles(), before);
      expect(logger.output, contains('Nothing was written'));
      expect(logger.output, contains('version: 1'));
    });

    test('refuses to overwrite an existing config without --force', () async {
      await run(<String>['import']);
      logger.lines.clear();

      expect(await run(<String>['import']), TaxiwayExit.userError);
      expect(logger.output, contains('--force'));
    });

    test('--force overwrites', () async {
      await run(<String>['import']);
      expect(await run(<String>['import', '--force']), TaxiwayExit.success);
    });

    test('records every discovered file as unmanaged', () async {
      await run(<String>['import']);
      final lock = project.read('.taxiway/lock.json');
      expect(lock, contains('"ownership": "unmanaged"'));
      expect(lock, isNot(contains('"adopted"')));
      expect(lock, isNot(contains('"generated"')));
      expect(lock, contains('android/app/build.gradle.kts'));
    });

    test('reports the flavors it found', () async {
      await run(<String>['import']);
      expect(logger.output, contains('Flavors found:'));
      expect(logger.output, contains('dev'));
      expect(logger.output, contains('android + ios'));
    });

    test('outside a Flutter project it is a user error', () async {
      final empty = await FixtureProject.create();
      addTearDown(empty.dispose);
      final exit = await TaxiwayCommandRunner(
        logger: logger,
        runner: runner,
        workingDirectory: empty.path,
      ).run(<String>['import']);
      expect(exit, TaxiwayExit.userError);
      expect(logger.output, contains('pubspec.yaml'));
    });
  });

  group('taxiway status', () {
    test('reports zero drift straight after import', () async {
      await run(<String>['import']);
      logger.lines.clear();

      expect(await run(<String>['status']), TaxiwayExit.success);
      expect(logger.output, contains('In sync.'));
    });

    test('reports a flavor added after import', () async {
      await run(<String>['import']);
      logger.lines.clear();

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
        }
        create("prod") { dimension = "environment" }
        create("staging") {
            dimension = "environment"
            applicationIdSuffix = ".staging"
        }
    }
}
''');

      await run(<String>['status']);
      expect(logger.output, contains('Drift'));
      expect(logger.output, contains('staging'));
    });

    test('says taxiway owns nothing yet', () async {
      await run(<String>['import']);
      logger.lines.clear();
      await run(<String>['status']);
      expect(logger.output, contains('unmanaged'));
      expect(logger.output, contains('taxiway adopt'));
    });

    test('without a config it is a user error naming the next step', () async {
      expect(await run(<String>['status']), TaxiwayExit.userError);
      expect(logger.output, contains('taxiway import'));
    });

    test('--json is machine readable', () async {
      await run(<String>['import']);
      logger.lines.clear();
      await run(<String>['status', '--json']);
      expect(logger.output, contains('"inSync": true'));
      expect(logger.output, contains('"ownership"'));
    });
  });

  group('taxiway init', () {
    test('describes an existing project rather than prompting', () async {
      expect(await run(<String>['--yes', 'init']), TaxiwayExit.success);
      expect(logger.output, contains('Found 2 flavors: dev, prod'));
      expect(logger.output, contains('Wrote taxiway.yaml'));
      expect(logger.output, contains('No project files were modified.'));
      expect(project.exists('taxiway.yaml'), isTrue);
    });

    test('points at status and import when a config already exists', () async {
      await run(<String>['--yes', 'init']);
      logger.lines.clear();

      expect(await run(<String>['init']), TaxiwayExit.success);
      expect(logger.output, contains('already exists'));
      expect(logger.output, contains('taxiway status'));
      // It must not silently rewrite a config the user may have edited.
      expect(logger.output, contains('--force'));
    });

    test('an empty Flutter project is told what to do next', () async {
      final bare = await FixtureProject.create();
      addTearDown(bare.dispose);
      bare.withPubspec();

      final exit = await TaxiwayCommandRunner(
        logger: logger,
        runner: runner,
        workingDirectory: bare.path,
      ).run(<String>['--no-color', '--yes', 'init']);

      expect(exit, TaxiwayExit.success);
      expect(logger.output, contains('nothing for taxiway to describe'));
      expect(logger.output, contains('flutter create'));
      expect(File('${bare.path}/taxiway.yaml').existsSync(), isFalse);
    });
  });
}
