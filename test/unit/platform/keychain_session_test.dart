import 'package:taxiway/src/core/env/run_environment.dart';
import 'package:taxiway/src/core/io/redactor.dart';
import 'package:taxiway/src/core/secrets/secret_names.dart';
import 'package:taxiway/src/platform/macos/keychain_session.dart';
import 'package:test/test.dart';

import '../../support/recording_process_runner.dart';

void main() {
  late RecordingProcessRunner runner;
  late Redactor redactor;

  setUp(() {
    runner = RecordingProcessRunner();
    redactor = Redactor();
    // The search list as a stock machine reports it.
    runner.stub(
      'security list-keychains',
      stdout:
          '    "/Users/dev/Library/Keychains/login.keychain-db"\n'
          '    "/Library/Keychains/System.keychain"',
    );
    runner.stub('security create-keychain');
    runner.stub('security set-keychain-settings');
    runner.stub('security unlock-keychain');
    runner.stub('security delete-keychain');
  });

  Future<KeychainSession?> open({
    RunEnvironment environment = RunEnvironment.ephemeralCi,
    Map<String, String> processEnvironment = const <String, String>{},
    bool isMacOS = true,
  }) => KeychainSession.open(
    environment: environment,
    runner: runner,
    redactor: redactor,
    processEnvironment: processEnvironment,
    isMacOS: isMacOS,
  );

  group('when no keychain is wanted', () {
    test(
      'a workstation uses the login keychain and nothing is created',
      () async {
        // A developer's certificates belong where Xcode will show them.
        expect(await open(environment: RunEnvironment.workstation), isNull);
        expect(
          runner.invocations.where((i) => i.executable == 'security'),
          isEmpty,
        );
      },
    );

    test('nothing happens off macOS', () async {
      expect(await open(isMacOS: false), isNull);
    });
  });

  group('setting one up', () {
    test('never changes the default keychain', () async {
      // The single most important property. Changing the default is a change
      // for every other process on the machine, and it is what makes
      // `setup_ci` unsafe on anything shared.
      await open();
      for (final invocation in runner.invocations) {
        expect(
          invocation.arguments,
          isNot(contains('default-keychain')),
          reason: invocation.arguments.join(' '),
        );
      }
    });

    test('appends to the search list, keeping what was there', () async {
      final session = await open();
      final setList = runner.invocations.lastWhere(
        (i) =>
            i.arguments.contains('list-keychains') &&
            i.arguments.contains('-s'),
      );

      expect(
        setList.arguments,
        containsAllInOrder(<String>[
          '/Users/dev/Library/Keychains/login.keychain-db',
          '/Library/Keychains/System.keychain',
          session!.name,
        ]),
        reason: 'the existing entries must survive, and ours goes last',
      );
    });

    test('does not auto-lock partway through a build', () async {
      await open();
      final settings = runner.invocations.firstWhere(
        (i) => i.arguments.contains('set-keychain-settings'),
      );
      // A keychain that relocks mid-build fails signing with an error naming
      // nothing useful.
      expect(settings.arguments, contains('-lut'));
    });

    test('uses a supplied password when one is given', () async {
      await open(
        processEnvironment: <String, String>{
          SecretNames.keychainPassword: 'from-the-environment',
        },
      );
      final created = runner.invocations.firstWhere(
        (i) => i.arguments.contains('create-keychain'),
      );
      expect(created.arguments, contains('from-the-environment'));
    });

    test('generates a real password when none is given', () async {
      final session = await open();
      final password = session!.environment['MATCH_KEYCHAIN_PASSWORD'];

      // `setup_ci` uses an empty one. This keychain may sit somewhere other
      // people can reach.
      expect(password, isNotNull);
      expect(password, isNotEmpty);
      expect(password!.length, greaterThan(16));
    });

    test('the password is redacted before it is ever used', () async {
      final session = await open();
      final password = session!.environment['MATCH_KEYCHAIN_PASSWORD']!;

      // It goes onto a `security` command line that verbose mode prints.
      expect(
        redactor.redact('security -p $password'),
        isNot(contains(password)),
      );
    });
  });

  group('what fastlane is handed', () {
    test('enough for setup_ci to stand down', () async {
      // `setup_ci` skips itself entirely when MATCH_KEYCHAIN_NAME is set, so
      // this cooperates with fastlane rather than fighting it.
      final session = await open();
      expect(session!.environment['MATCH_KEYCHAIN_NAME'], session.name);
      expect(session.environment['MATCH_KEYCHAIN_PASSWORD'], isNotEmpty);
    });

    test('match is readonly', () async {
      // A build must never mint a certificate: they are limited and shared,
      // and a runner creating one per build exhausts the team's allowance.
      final session = await open();
      expect(session!.environment['MATCH_READONLY'], 'true');
    });
  });

  group('teardown', () {
    test('restores the search list exactly and deletes the keychain', () async {
      final session = await open();
      runner.invocations.clear();

      await session!.close();

      final restore = runner.invocations.firstWhere(
        (i) => i.arguments.contains('list-keychains'),
      );
      expect(
        restore.arguments.where((a) => a.contains('keychain-db')).toList(),
        <String>['/Users/dev/Library/Keychains/login.keychain-db'],
        reason: 'ours must be gone from the list it restores',
      );
      expect(
        runner.invocations.any((i) => i.arguments.contains('delete-keychain')),
        isTrue,
      );
    });

    test('is safe to call twice', () async {
      final session = await open();
      await session!.close();
      runner.invocations.clear();

      await session.close();
      // A teardown that runs twice must not run twice.
      expect(runner.invocations, isEmpty);
    });

    test('a failure partway through still tears down', () async {
      // A half-made keychain is worse than none: it is in the search list and
      // signs nothing.
      runner.stub('security list-keychains -d user -s', exitCode: 1);

      await expectLater(open(), throwsA(isA<KeychainFailure>()));
      expect(
        runner.invocations.any((i) => i.arguments.contains('delete-keychain')),
        isTrue,
        reason: 'the keychain it created must not be left behind',
      );
    });
  });
}
