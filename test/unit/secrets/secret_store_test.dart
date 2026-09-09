import 'package:taxiway/src/core/env/host_platform.dart';
import 'package:taxiway/src/core/io/redactor.dart';
import 'package:taxiway/src/secrets/secret_store.dart';
import 'package:test/test.dart';

import '../../support/recording_process_runner.dart';

void main() {
  late RecordingProcessRunner runner;
  late Redactor redactor;

  setUp(() {
    runner = RecordingProcessRunner();
    redactor = Redactor();
  });

  SecretStore store({HostPlatform host = HostPlatform.macos}) =>
      SecretStore(runner: runner, redactor: redactor, host: host);

  group('the value never reaches a command line', () {
    test('it is written to stdin, twice, and appears in no argument', () async {
      // `ps` on a shared machine shows every argument of every running
      // process. A credential passed as one is readable by anybody with an
      // account on the box for as long as the command takes to run.
      await store().set('MATCH_PASSWORD', 'hunter2');

      final add = runner.invocation('add-generic-password');
      expect(add.arguments, isNot(contains('hunter2')));
      expect(add.arguments.last, '-w', reason: '-w with no value reads stdin');
      // Twice: `security` reads the value and then a confirmation.
      expect(add.stdin, 'hunter2\nhunter2\n');
    });

    test('and is registered with the redactor', () async {
      await store().set('MATCH_PASSWORD', 'hunter2');

      expect(
        redactor.redact('the password is hunter2'),
        isNot(contains('hunter2')),
      );
    });

    test('replacing an existing item is an update, not a failure', () async {
      // Without -U, `security` refuses rather than overwriting, and setting a
      // rotated credential would fail on every machine that already had one.
      await store().set('MATCH_PASSWORD', 'hunter2');

      expect(
        runner.invocation('add-generic-password').arguments,
        contains('-U'),
      );
    });
  });

  group('a write that did not write', () {
    test(
      'a refused confirmation is caught, though the exit code is 0',
      () async {
        // The failure this verification exists for: given a value and a
        // confirmation that differ, `security` says so, stores nothing, and
        // still exits 0.
        runner.stub(
          'add-generic-password',
          stderr:
              'password data for new item: '
              '${SecretStore.mismatchSignature}',
        );

        await expectLater(
          store().set('MATCH_PASSWORD', 'hunter2'),
          throwsA(isA<SecretStoreFailure>()),
        );
      },
    );

    test('an item that is not there afterwards is caught too', () async {
      // Belt and braces: if the refusal message ever changes, absence still
      // says the write did not happen.
      runner.stub('find-generic-password', exitCode: 44);

      await expectLater(
        store().set('MATCH_PASSWORD', 'hunter2'),
        throwsA(isA<SecretStoreFailure>()),
      );
    });

    test('nothing is read back, not even to check its own work', () async {
      // A value travels one way through this type. The check asks whether the
      // item exists, which needs no -w and hands no secret back.
      await store().set('MATCH_PASSWORD', 'hunter2');

      final find = runner.invocation('find-generic-password');
      expect(find.arguments, isNot(contains('-w')));
    });
  });

  group('what it refuses to hold', () {
    test('a multi-line value, because only two lines would survive', () async {
      // `security` reads one line as the value and the next as its
      // confirmation, so a PEM would silently become its first line compared
      // against its second.
      await expectLater(
        store().set('MATCH_GIT_PRIVATE_KEY', '-----BEGIN\nkey\n-----END'),
        throwsA(
          isA<SecretStoreFailure>().having(
            (f) => f.fixHint,
            'fixHint',
            contains('--base64'),
          ),
        ),
      );
      expect(runner.invocations, isEmpty, reason: 'refused before running');
    });

    test('an empty value', () async {
      await expectLater(
        store().set('MATCH_PASSWORD', ''),
        throwsA(isA<SecretStoreFailure>()),
      );
    });

    test(
      'anything at all, off macOS, and says where to put it instead',
      () async {
        await expectLater(
          store(host: HostPlatform.linux).set('MATCH_PASSWORD', 'hunter2'),
          throwsA(
            isA<SecretStoreFailure>().having(
              (f) => f.fixHint,
              'fixHint',
              contains('.env'),
            ),
          ),
        );
        expect(runner.invocations, isEmpty);
      },
    );
  });

  test('has() asks without reading, and is false off macOS', () async {
    expect(await store().has('MATCH_PASSWORD'), isTrue);
    expect(
      runner.invocation('find-generic-password').arguments,
      isNot(contains('-w')),
    );

    runner.clear();
    expect(
      await store(host: HostPlatform.linux).has('MATCH_PASSWORD'),
      isFalse,
    );
    expect(runner.invocations, isEmpty);
  });
}
