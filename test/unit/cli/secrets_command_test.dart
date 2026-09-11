import 'package:mason_logger/mason_logger.dart';
import 'package:shipway/src/cli/exit_codes.dart';
import 'package:shipway/src/cli/shipway_command_runner.dart';
import 'package:shipway/src/core/env/host_platform.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';
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

const String _config = '''
version: 1
project:
  name: demo_app
apps:
  main:
    path: .
    flavors:
      prod:
        suffix: ""
    signing:
      ios:
        match_git_url: https://github.com/acme/certs.git
        team_id: ABCDE12345
        api_key:
          key_id_ref: ASC_KEY_ID
          issuer_id_ref: ASC_ISSUER_ID
          p8_ref: ASC_KEY_P8_BASE64
''';

/// Models an empty login keychain that fills up as values are added.
///
/// The recording runner answers everything with success by default, which
/// means `find-generic-password` reports every name as already stored — so a
/// test of storing would silently exercise the skip path instead.
void emptyKeychain(RecordingProcessRunner runner) {
  runner
    ..stub('find-generic-password', exitCode: 44)
    ..onRun = (invocation) {
      if (!invocation.commandLine.contains('add-generic-password')) return;
      final arguments = invocation.arguments;
      final name = arguments[arguments.indexOf('-a') + 1];
      runner.stub('-a $name');
    };
}

void main() {
  late FixtureProject project;
  late _CapturingLogger logger;
  late RecordingProcessRunner runner;

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
    project.write('shipway.yaml', _config);
    logger = _CapturingLogger();
    runner = RecordingProcessRunner();
  });

  Future<int> run(List<String> args, {HostPlatform? host}) =>
      ShipwayCommandRunner(
        logger: logger,
        runner: runner,
        workingDirectory: project.path,
        host: host ?? HostPlatform.macos,
      ).run(<String>['--config=${project.path}/shipway.yaml', ...args]);

  group('set', () {
    test('takes the value from a file without it reaching a log', () async {
      project.write('key.txt', 'a-secret-value\n');

      final code = await run(<String>[
        'secrets',
        'set',
        'ASC_KEY_ID',
        '--from-file=key.txt',
      ]);

      expect(code, ShipwayExit.success);
      expect(logger.output, contains('Stored ASC_KEY_ID'));
      // The whole point: what was stored is never shown.
      expect(logger.output, isNot(contains('a-secret-value')));
      expect(
        runner.invocation('add-generic-password').stdin,
        'a-secret-value\na-secret-value\n',
        reason: 'the trailing newline is not part of the value',
      );
    });

    test('--base64 encodes the file, so the lane can decode it', () async {
      // Done here rather than told to the user because `base64` on Linux wraps
      // at 76 columns by default, and the wrapped form does not decode.
      project.write('key.txt', 'p8-contents');

      await run(<String>[
        'secrets',
        'set',
        'ASC_KEY_P8_BASE64',
        '--from-file=key.txt',
        '--base64',
      ]);

      expect(
        runner.invocation('add-generic-password').stdin,
        startsWith('cDgtY29udGVudHM='),
      );
    });

    test('says which credential when given none', () async {
      final code = await run(<String>['secrets', 'set']);

      expect(code, ShipwayExit.userError);
      expect(logger.output, contains('ASC_KEY_ID'));
      expect(runner.invocations, isEmpty);
    });

    test('will not prompt where a prompt would hang', () async {
      // On a runner there is nobody to answer, and a hang burns the job
      // timeout while reporting nothing.
      final code = await run(<String>[
        '--env=ci',
        'secrets',
        'set',
        'ASC_KEY_ID',
      ]);

      expect(code, ShipwayExit.userError);
      expect(logger.output, contains('--stdin'));
      expect(runner.invocations, isEmpty);
    });

    test(
      'off macOS it fails as an environment problem, not a mistake',
      () async {
        project.write('key.txt', 'value');

        final code = await run(<String>[
          'secrets',
          'set',
          'ASC_KEY_ID',
          '--from-file=key.txt',
        ], host: HostPlatform.linux);

        expect(code, ShipwayExit.environmentError);
        expect(logger.output, contains('.env'));
      },
    );
  });

  group('import', () {
    test('stores every assignment and leaves the file alone', () async {
      emptyKeychain(runner);
      project.write('.env', '''
# a comment
ASC_KEY_ID=key-id
export ASC_ISSUER_ID="issuer id"
''');

      final code = await run(<String>['secrets', 'import']);

      expect(code, ShipwayExit.success);
      expect(logger.output, contains('2 stored'));
      expect(project.exists('.env'), isTrue);
      // Copied, not moved — and the report has to say so, or somebody deletes
      // a file believing shipway already did.
      expect(logger.output, contains('unchanged'));
    });

    test('keeps what is already stored unless forced', () async {
      project.write('.env', 'ASC_KEY_ID=key-id\n');
      runner.stub('find-generic-password', stdout: 'present');

      await run(<String>['secrets', 'import']);

      expect(logger.output, contains('1 already there'));
      expect(runner.ran('add-generic-password'), isFalse);
    });

    test('a missing file is a user error, not a silent success', () async {
      final code = await run(<String>['secrets', 'import', '--from=.env.nope']);

      expect(code, ShipwayExit.userError);
      expect(logger.output, contains('.env.nope'));
    });
  });

  group('export', () {
    test('emits names and never touches the keychain', () async {
      final code = await run(<String>['secrets', 'export']);

      expect(code, ShipwayExit.success);
      expect(logger.output, contains('gh secret set ASC_KEY_ID'));
      expect(runner.invocations, isEmpty);
    });

    test('a team id in the config is not asked for as a secret', () async {
      // It appears in every build log, so the workflow writes it plainly.
      // Asking for it as a repository secret would hide nothing and add a
      // step that can be got wrong.
      await run(<String>['secrets', 'export']);

      expect(logger.output, isNot(contains('DEVELOPER_PORTAL_TEAM_ID')));
    });
  });

  test('an unknown action names the ones that exist', () async {
    final code = await run(<String>['secrets', 'nonsense']);

    expect(code, ShipwayExit.userError);
    expect(logger.output, contains('export'));
  });
}
