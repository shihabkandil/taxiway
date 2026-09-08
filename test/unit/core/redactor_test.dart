import 'package:taxiway/src/core/io/redactor.dart';
import 'package:test/test.dart';

/// A realistically-shaped private key. Not a real one — the body is filler —
/// but it exercises the PEM path, which is the shape that actually leaks.
const _p8 = '''
-----BEGIN PRIVATE KEY-----
MIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQgEXAMPLEkeyMaterial
aGVyZUZvclRlc3RpbmdPbmx5oAoGCCqGSM49AwEHoUQDQgAEEXAMPLEpublicPart
-----END PRIVATE KEY-----''';

void main() {
  group('Redactor', () {
    test('replaces a registered value', () {
      final redactor = Redactor()..register('hunter2secret');
      expect(
        redactor.redact('password=hunter2secret done'),
        'password=*** done',
      );
    });

    test('leaves output alone when nothing is registered', () {
      expect(Redactor().redact('all clear'), 'all clear');
    });

    test('ignores values too short to be worth matching', () {
      final redactor = Redactor()..register('ab');
      expect(redactor.redact('ab ab ab'), 'ab ab ab');
    });

    test('redacts the base64 form of a registered value', () {
      final redactor = Redactor()..register('keystore-password');
      // What a lane would print if it base64'd the value before use.
      expect(
        redactor.redact('a2V5c3RvcmUtcGFzc3dvcmQ='),
        contains('***'),
      );
    });

    test('redacts the URL-encoded form', () {
      final redactor = Redactor()..register('p@ss word/value');
      expect(
        redactor.redact('https://x/?t=p%40ss%20word%2Fvalue'),
        'https://x/?t=***',
      );
    });

    test('redacts an individual PEM body line', () {
      final redactor = Redactor()..register(_p8);
      const oneLine =
          'aGVyZUZvclRlc3RpbmdPbmx5oAoGCCqGSM49AwEHoUQDQgAEEXAMPLEpublicPart';
      expect(redactor.redact('key: $oneLine'), 'key: ***');
    });

    test('redacts the whole PEM', () {
      final redactor = Redactor()..register(_p8);
      expect(redactor.redact('sending $_p8 now'), isNot(contains('MIGTAgEA')));
    });

    test('prefers the longest match when secrets overlap', () {
      final redactor = Redactor()
        ..register('secretvalue')
        ..register('secretvalue-extended');
      expect(redactor.redact('x secretvalue-extended y'), 'x *** y');
    });
  });

  group('Redactor.redactStream', () {
    Future<String> pipe(Redactor redactor, List<String> chunks) async =>
        redactor.redactStream(Stream<String>.fromIterable(chunks)).join();

    test('passes through untouched when nothing is registered', () async {
      expect(await pipe(Redactor(), ['abc', 'def']), 'abcdef');
    });

    test('redacts a secret split across two chunks', () async {
      final redactor = Redactor()..register('SUPERSECRET');
      // The bug this class would otherwise have: each half is innocuous.
      expect(await pipe(redactor, ['token=SUPER', 'SECRET\n']), 'token=***\n');
    });

    test('redacts a secret split one character at a time', () async {
      final redactor = Redactor()..register('SUPERSECRET');
      final chunks = 'noise SUPERSECRET noise'.split('');
      expect(await pipe(redactor, chunks), 'noise *** noise');
    });

    test('redacts a PEM arriving in small chunks', () async {
      final redactor = Redactor()..register(_p8);
      final chunks = <String>[];
      for (var i = 0; i < _p8.length; i += 7) {
        chunks.add(_p8.substring(i, (i + 7).clamp(0, _p8.length)));
      }
      final out = await pipe(redactor, chunks);
      expect(out, isNot(contains('MIGTAgEA')));
      expect(out, isNot(contains('aGVyZUZvclRlc3Rpbmc')));
    });

    test('emits everything when no secret is present', () async {
      final redactor = Redactor()..register('nevermatched');
      expect(await pipe(redactor, ['hello ', 'world']), 'hello world');
    });

    test('flushes a trailing partial buffer', () async {
      final redactor = Redactor()..register('averylongsecretvalue');
      expect(await pipe(redactor, ['tail']), 'tail');
    });
  });
}
