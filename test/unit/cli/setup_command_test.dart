import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:taxiway/src/cli/exit_codes.dart';
import 'package:taxiway/src/cli/taxiway_command_runner.dart';
import 'package:taxiway/src/core/config/config_loader.dart';
import 'package:taxiway/src/core/env/host_platform.dart';
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
  name: acme_app
apps:
  main:
    path: .
    # QA lives here.
    flavors:
      prod:
        suffix: ""
''';

void main() {
  late FixtureProject project;
  late _CapturingLogger logger;
  late RecordingProcessRunner runner;

  /// keytool writes no file of its own here, so the double writes one for it —
  /// otherwise every run would report the failure the real tool has when a
  /// password and its confirmation differ.
  void keytoolWrites() {
    runner.onRun = (invocation) {
      if (!invocation.commandLine.contains('-genkeypair')) return;
      final arguments = invocation.arguments;
      final path = arguments[arguments.indexOf('-keystore') + 1];
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(<int>[0x50, 0x4b, 0x03, 0x04]);
    };
  }

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
    project.write('taxiway.yaml', _config);
    project.write('android/app/build.gradle.kts', 'android { }\n');
    logger = _CapturingLogger();
    runner = RecordingProcessRunner();
    keytoolWrites();
  });

  Future<int> run(List<String> args, {HostPlatform? host}) =>
      TaxiwayCommandRunner(
        logger: logger,
        runner: runner,
        workingDirectory: project.path,
        host: host ?? HostPlatform.macos,
      ).run(<String>['--config=${project.path}/taxiway.yaml', ...args]);

  group('android-signing', () {
    test(
      'the password reaches keytool on stdin, never as an argument',
      () async {
        // `ps` shows every argument of every running process, and key generation
        // is slow enough to read one off comfortably.
        final code = await run(<String>['setup', 'android-signing']);

        expect(code, TaxiwayExit.success);
        final keytool = runner.invocation('-genkeypair');
        expect(keytool.arguments, isNot(contains('-storepass')));
        expect(keytool.arguments, isNot(contains('-keypass')));
        // Twice: the value, then its confirmation.
        final stdin = keytool.stdin!;
        final lines = stdin.trimRight().split('\n');
        expect(lines, hasLength(2));
        expect(lines.first, lines.last);
        expect(lines.first, hasLength(32));
      },
    );

    test('the generated password is nowhere in the output', () async {
      await run(<String>['setup', 'android-signing']);

      final password = runner
          .invocation('-genkeypair')
          .stdin!
          .split('\n')
          .first;
      expect(logger.output, isNot(contains(password)));
    });

    test('key.properties points where Gradle resolves from', () async {
      // `storeFile` is resolved relative to android/app. A path relative to
      // the repository root fails by resolving to a file that is not there,
      // and an absolute one works on exactly one machine.
      await run(<String>['setup', 'android-signing']);

      final properties = project.read('android/key.properties');
      expect(properties, contains('storeFile=../upload-keystore.jks'));
      expect(properties, contains('keyAlias=upload'));
    });

    test('taxiway.yaml gains the names and no value', () async {
      await run(<String>['setup', 'android-signing']);

      final patched = project.read('taxiway.yaml');
      final android = ConfigLoader.parse(
        patched,
      ).apps['main']!.signing.android!;

      expect(android.keystoreRef, 'ANDROID_KEYSTORE_BASE64');
      expect(android.keyProperties!.keyAlias, 'upload');
      // The edit is surgical: the file is still the one somebody wrote.
      expect(patched, contains('# QA lives here.'));

      final password = runner
          .invocation('-genkeypair')
          .stdin!
          .split('\n')
          .first;
      expect(patched, isNot(contains(password)));
    });

    test('the passwords and the keystore go to the keychain', () async {
      await run(<String>['setup', 'android-signing']);

      final stored = <String>[
        for (final invocation in runner.invocations)
          if (invocation.commandLine.contains('add-generic-password'))
            invocation.arguments[invocation.arguments.indexOf('-a') + 1],
      ];
      expect(
        stored,
        containsAll(<String>[
          'ANDROID_STORE_PASSWORD',
          'ANDROID_KEY_PASSWORD',
          'ANDROID_KEYSTORE_BASE64',
        ]),
      );
    });

    test('an existing keystore is never overwritten', () async {
      // Losing an upload key means an app already on Play cannot be updated.
      project.write('android/upload-keystore.jks', 'the real one');

      final code = await run(<String>['setup', 'android-signing']);

      expect(code, TaxiwayExit.userError);
      expect(project.read('android/upload-keystore.jks'), 'the real one');
      expect(runner.ran('-genkeypair'), isFalse);
      expect(logger.output, contains('cannot be updated without it'));
    });

    test('names a team already uses rather than renaming them', () async {
      project.write('taxiway.yaml', '''
$_config    signing:
      android:
        keystore_ref: OUR_KEYSTORE
        key_properties:
          store_password_ref: OUR_STORE_PASSWORD
          key_password_ref: OUR_KEY_PASSWORD
''');

      await run(<String>['setup', 'android-signing']);

      final android = ConfigLoader.parse(
        project.read('taxiway.yaml'),
      ).apps['main']!.signing.android!;
      expect(android.keystoreRef, 'OUR_KEYSTORE');
      expect(android.keyProperties!.storePasswordRef, 'OUR_STORE_PASSWORD');
    });

    test('says so when Gradle would still use the debug key', () async {
      // Writing key.properties signs nothing on its own. A release built with
      // the debug key installs and uploads, and Play rejects it.
      await run(<String>['setup', 'android-signing']);

      expect(logger.output, contains('does not read key.properties'));
    });

    test('stays quiet when Gradle already reads it', () async {
      project.write(
        'android/app/build.gradle.kts',
        'val p = file("key.properties")\n',
      );

      await run(<String>['setup', 'android-signing']);

      expect(logger.output, isNot(contains('does not read key.properties')));
    });

    test('off macOS it refuses before creating anything', () async {
      final code = await run(<String>[
        'setup',
        'android-signing',
      ], host: HostPlatform.linux);

      expect(code, TaxiwayExit.environmentError);
      expect(runner.invocations, isEmpty);
      expect(project.exists('android/upload-keystore.jks'), isFalse);
    });
  });

  test('an unknown action names the ones that exist', () async {
    final code = await run(<String>['setup', 'nonsense']);

    expect(code, TaxiwayExit.userError);
    expect(logger.output, contains('android-signing'));
  });

  test('no action at all says what to pick', () async {
    final code = await run(<String>['setup']);

    expect(code, TaxiwayExit.userError);
    expect(logger.output, contains('android-signing'));
  });
}
