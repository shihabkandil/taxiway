import 'package:mason_logger/mason_logger.dart';
import 'package:taxiway/src/cli/exit_codes.dart';
import 'package:taxiway/src/cli/taxiway_command_runner.dart';
import 'package:taxiway/src/core/env/host_platform.dart';
import 'package:taxiway/src/version.dart';
import 'package:test/test.dart';

import '../../support/recording_process_runner.dart';

/// Captures what the CLI printed.
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
}

void main() {
  late _CapturingLogger logger;
  late RecordingProcessRunner runner;

  TaxiwayCommandRunner build({String? cwd, HostPlatform? host}) =>
      TaxiwayCommandRunner(
        logger: logger,
        runner: runner,
        workingDirectory: cwd ?? '.',
        host: host,
      );

  setUp(() {
    logger = _CapturingLogger();
    runner = RecordingProcessRunner();
  });

  group('global flags', () {
    test('--version prints the package version', () async {
      expect(await build().run(['--version']), TaxiwayExit.success);
      expect(logger.output, contains(packageVersion));
    });

    test('an unknown command is a user error with usage', () async {
      expect(await build().run(['nonsense']), TaxiwayExit.userError);
      expect(logger.output, contains('nonsense'));
      expect(logger.output, contains('Available commands'));
    });

    test('an unknown flag is a user error', () async {
      expect(await build().run(['doctor', '--nope']), TaxiwayExit.userError);
    });
  });

  group('doctor exit codes', () {
    void stubPassingTools() {
      runner
        ..stub('flutter --version', stdout: 'Flutter 3.47.2')
        ..stub('dart --version', stdout: 'Dart SDK version: 3.13.2')
        ..stub('xcodebuild -version', stdout: 'Xcode 26.6')
        ..stub('pod --version', stdout: '1.17.0')
        ..stub('ruby --version', stdout: 'ruby 3.4.1p18')
        ..stub('bundle --version', stdout: 'Bundler version 2.6.3')
        ..stub('fastlane --version', stdout: 'fastlane 2.238.0')
        ..stub('java -version', stderr: 'openjdk version "21.0.4"')
        ..stub('security list-keychains', stdout: '"login.keychain-db"');
    }

    test('returns 0 when nothing blocks shipping', () async {
      stubPassingTools();
      expect(await build().run(['doctor']), TaxiwayExit.success);
    });

    test('returns 2 — an environment failure — when a check fails', () async {
      runner.stub('ruby --version', stdout: 'ruby 2.6.0p0');
      expect(
        await build().run(['doctor', '--only', 'ruby']),
        TaxiwayExit.environmentError,
      );
      expect(logger.output, contains('2.6.0 found'));
    });

    test(
      '--only with an unknown id is a user error listing valid ids',
      () async {
        expect(
          await build().run(['doctor', '--only', 'banana']),
          TaxiwayExit.userError,
        );
        expect(logger.output, contains('Available:'));
        expect(logger.output, contains('fastlane'));
      },
    );

    test('--json emits parseable output', () async {
      runner.stub('ruby --version', stdout: 'ruby 3.4.1p18');
      await build().run(['doctor', '--only', 'ruby', '--json']);
      expect(logger.output, contains('"passed"'));
      expect(logger.output, contains('"deadlineDataLastVerified"'));
    });

    test('--no-color strips ANSI escapes', () async {
      runner.stub('ruby --version', stdout: 'ruby 3.4.1p18');
      await build().run(['doctor', '--only', 'ruby', '--no-color']);
      expect(logger.output, isNot(contains('[')));
    });
  });

  group('commands go through ProcessRunner', () {
    test('doctor never spawns a process itself', () async {
      runner.stub('ruby --version', stdout: 'ruby 3.4.1p18');
      await build().run(['doctor', '--only', 'ruby']);
      // If doctor had shelled out directly, the recorder would be empty and the
      // check would have read this machine instead of the stub.
      expect(runner.ran('ruby --version'), isTrue);
      expect(runner.invocations, hasLength(1));
    });
  });

  group('config errors', () {
    test(
      'a broken config does not stop doctor reporting on the environment',
      () async {
        runner.stub('ruby --version', stdout: 'ruby 3.4.1p18');
        final exit =
            await TaxiwayCommandRunner(
              logger: logger,
              runner: runner,
              workingDirectory: 'test/fixtures/config/invalid',
            ).run([
              'doctor',
              '--only',
              'ruby',
              '--config',
              'test/fixtures/config/invalid/bad_version.yaml',
            ]);
        expect(exit, TaxiwayExit.success);
        expect(logger.output, contains('Could not read taxiway.yaml'));
        expect(logger.output, contains('Ruby'));
      },
    );
  });

  group('a machine that cannot build iOS', () {
    test('refuses `build ios` and names what it can build', () async {
      // The refusal has to arrive before anything slow, and it has to say
      // where to go next: "needs macOS" alone leaves someone on a Linux
      // builder wondering whether taxiway is any use to them.
      final code = await build(
        host: HostPlatform.linux,
      ).run(<String>['build', 'ios']);

      expect(code, TaxiwayExit.environmentError);
      expect(logger.output, contains('Linux'));
      expect(logger.output, contains('taxiway build android'));
    });
  });
}
