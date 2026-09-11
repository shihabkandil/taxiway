import 'dart:convert';
import 'dart:io';

import 'package:shipway/src/platform/ios/xcode_project_mutator.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';
import '../../support/recording_process_runner.dart';

/// The exact bytes a fixture project starts with, so a restore can be checked
/// for byte-equality rather than "looks about right".
const String _originalPbxproj = '// !\$*UTF8*\$!\n{ objectVersion = 60; }\n';

void main() {
  late RecordingProcessRunner runner;
  late FixtureProject project;

  setUp(() async {
    runner = RecordingProcessRunner();
    project = await FixtureProject.create();
    addTearDown(project.dispose);
    project
      ..withPubspec()
      ..withIosProject();
  });

  XcodeProjectMutator mutator() => XcodeProjectMutator(
    runner: runner,
    scriptPath: 'tool/ruby/xcodeproj_bridge.rb',
    root: project.path,
  );

  List<DesiredConfiguration> devAndProd() =>
      XcodeProjectMutator.configurationsFor(const <String>['dev', 'prod']);

  group('configurationsFor', () {
    test('produces all three build types per flavor', () {
      final configurations = devAndProd();
      expect(configurations.map((c) => c.name), <String>[
        'Debug-dev',
        'Release-dev',
        'Profile-dev',
        'Debug-prod',
        'Release-prod',
        'Profile-prod',
      ]);
      expect(configurations.first.basedOn, 'Debug');
    });

    test('never attaches an xcconfig, and inherits the build type\'s', () {
      // The whole point: `Release-dev` must read whatever `Release` reads, so
      // that Generated.xcconfig — and with it FLUTTER_TARGET, the dart-defines
      // and the version numbers — still reaches a flavored build.
      for (final configuration in devAndProd()) {
        expect(configuration.xcconfig, isNull);
        expect(configuration.inheritBaseConfiguration, isTrue);
        expect(configuration.toJson()['inheritBaseConfiguration'], isTrue);
        expect(configuration.toJson().containsKey('xcconfig'), isFalse);
      }
    });

    test('puts the team id on the configuration itself', () {
      final configurations = XcodeProjectMutator.configurationsFor(
        const <String>['dev'],
        teamId: 'ABCDE12345',
      );
      expect(
        configurations.first.buildSettings['DEVELOPMENT_TEAM'],
        'ABCDE12345',
      );
    });
  });

  group('the request sent to the bridge', () {
    setUp(() => stubConfigure(runner, flavors: const <String>['dev', 'prod']));

    test('invokes the configure op on the project directory', () async {
      await mutator().configure(configurations: devAndProd());

      final invocation = runner.invocation('configure');
      expect(invocation.executable, 'ruby');
      expect(invocation.arguments[0], 'tool/ruby/xcodeproj_bridge.rb');
      expect(invocation.arguments[1], 'configure');
      expect(invocation.arguments[2], endsWith('ios/Runner.xcodeproj'));
    });

    test('sends the payload on stdin, not as an argument', () async {
      await mutator().configure(configurations: devAndProd());

      final invocation = runner.invocation('configure');
      // A project with many flavors produces a payload well past a comfortable
      // argv length, so it must not be an argument.
      expect(invocation.stdin, isNotNull);
      expect(invocation.arguments, hasLength(3));

      final request = jsonDecode(invocation.stdin!) as Map<String, dynamic>;
      expect(request['target'], 'Runner');
      final configurations = (request['configurations'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(configurations, hasLength(6));
      expect(configurations.first['name'], 'Debug-dev');
      expect(configurations.first['basedOn'], 'Debug');
      expect(configurations.first['inheritBaseConfiguration'], isTrue);
    });

    test(
      'omits the run script when no flavor declares a Firebase plist',
      () async {
        await mutator().configure(configurations: devAndProd());
        final request =
            jsonDecode(runner.invocation('configure').stdin!)
                as Map<String, dynamic>;
        expect(request.containsKey('runScript'), isFalse);
      },
    );

    test('includes a named run script when plists are declared', () async {
      await mutator().configure(
        configurations: devAndProd(),
        firebasePlists: <String, String>{
          'Release-dev': 'ios/config/dev/GoogleService-Info.plist',
        },
      );

      final request =
          jsonDecode(runner.invocation('configure').stdin!)
              as Map<String, dynamic>;
      final script = request['runScript'] as Map<String, dynamic>;
      expect(script['name'], XcodeProjectMutator.firebasePhaseName);
      expect(script['script'], contains('Release-dev'));
      expect(script['script'], contains('GoogleService-Info.plist'));
    });
  });

  group('the Firebase script', () {
    test('is null when there is nothing to copy', () {
      expect(
        XcodeProjectMutator.firebaseScript(const <String, String>{}),
        isNull,
      );
    });

    test('branches on CONFIGURATION and fails loudly on a missing plist', () {
      final script = XcodeProjectMutator.firebaseScript(<String, String>{
        'Release-dev': 'ios/config/dev/GoogleService-Info.plist',
        'Release-prod': 'ios/config/prod/GoogleService-Info.plist',
      })!;

      expect(script, contains(r'case "$CONFIGURATION" in'));
      expect(script, contains('"Release-dev")'));
      expect(script, contains('"Release-prod")'));
      // Shipping an app pointed at the wrong Firebase project is worse than a
      // failed build, so a missing plist is an error, not a warning.
      expect(script, contains('error: shipway:'));
      expect(script, contains('exit 1'));
    });
  });

  group('backups', () {
    test('writes a copy before touching the project', () async {
      stubConfigure(runner, flavors: const <String>['dev', 'prod']);

      final result = await mutator().configure(configurations: devAndProd());

      expect(result.succeeded, isTrue);
      expect(result.backupPath, isNotNull);
      expect(result.backupPath, startsWith('.shipway/backups/'));
      expect(project.read(result.backupPath!), _originalPbxproj);
    });
  });

  group('failure restores the original file', () {
    Future<void> expectRestored(MutationResult result) async {
      expect(result.succeeded, isFalse);
      expect(result.restored, isTrue);
      // Byte-identical, which is the whole promise.
      expect(project.read(XcodeProjectMutator.pbxprojPath), _originalPbxproj);
    }

    test('a bridge error is reported with its remedy', () async {
      runner.stub(
        'xcodeproj_bridge.rb configure',
        exitCode: 1,
        stdout: jsonEncode(<String, Object?>{
          'ok': false,
          'error': <String, Object?>{
            'code': 'configure_failed',
            'message': 'Could not configure: boom',
            'remedy': 'Open it in Xcode.',
          },
        }),
      );

      final result = await mutator().configure(configurations: devAndProd());

      await expectRestored(result);
      expect(result.failureReason, contains('boom'));
      expect(result.failureRemedy, contains('Xcode'));
    });

    test('non-JSON output is a failure, not a bad parse', () async {
      runner.stub(
        'xcodeproj_bridge.rb configure',
        exitCode: 1,
        stdout: 'undefined method `foo` for nil:NilClass',
      );

      await expectRestored(
        await mutator().configure(configurations: devAndProd()),
      );
    });

    test('a missing Ruby is reported with an install hint', () async {
      runner.stub('xcodeproj_bridge.rb configure', exitCode: 127);

      final result = await mutator().configure(configurations: devAndProd());

      await expectRestored(result);
      expect(result.failureReason, contains('Ruby'));
      expect(result.failureRemedy, contains('gem install xcodeproj'));
    });

    test(
      'a bridge that claims success without doing the work is caught',
      () async {
        // The verification step exists for exactly this: "ok" is a claim, and
        // the project either declares the configurations or it does not.
        stubConfigure(runner, flavors: const <String>['dev']);

        final result = await mutator().configure(configurations: devAndProd());

        await expectRestored(result);
        expect(result.failureReason, contains('Debug-prod'));
        expect(result.failureRemedy, contains('restored'));
      },
    );
  });

  group('preconditions', () {
    test('a project with no pbxproj fails before running anything', () async {
      final bare = await FixtureProject.create();
      addTearDown(bare.dispose);
      bare.withPubspec();

      final result = await XcodeProjectMutator(
        runner: runner,
        scriptPath: 'tool/ruby/xcodeproj_bridge.rb',
        root: bare.path,
      ).configure(configurations: devAndProd());

      expect(result.succeeded, isFalse);
      expect(result.failureRemedy, contains('flutter create'));
      expect(runner.invocations, isEmpty);
    });

    test('no configurations means no process and no backup', () async {
      final result = await mutator().configure(
        configurations: const <DesiredConfiguration>[],
      );

      expect(result.succeeded, isTrue);
      expect(result.changed, isFalse);
      expect(result.backupPath, isNull);
      expect(runner.invocations, isEmpty);
      expect(
        Directory('${project.path}/.shipway/backups').existsSync(),
        isFalse,
      );
    });
  });

  group('idempotence', () {
    test('an unchanged project reports no change', () async {
      stubConfigure(
        runner,
        flavors: const <String>['dev', 'prod'],
        changed: false,
      );

      final result = await mutator().configure(configurations: devAndProd());

      expect(result.succeeded, isTrue);
      expect(result.changed, isFalse);
      expect(result.changes, isEmpty);
    });
  });
}
