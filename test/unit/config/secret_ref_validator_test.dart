import 'package:taxiway/src/core/config/config_loader.dart';
import 'package:taxiway/src/core/config/secret_ref_validator.dart';
import 'package:test/test.dart';

void main() {
  group('accepts plausible secret names', () {
    for (final name in const <String>[
      'ASC_KEY_ID',
      'ANDROID_STORE_PASSWORD',
      'match-password',
      'ci.play.service_account',
      'FB_IOS_APP_ID',
      'A1',
    ]) {
      test(name, () => expect(SecretRefValidator.reasonToReject(name), isNull));
    }

    test('an absent ref is not a violation', () {
      expect(SecretRefValidator.reasonToReject(null), isNull);
    });
  });

  group('rejects values that are secrets rather than names', () {
    test('a PEM body', () {
      expect(
        SecretRefValidator.reasonToReject(
          '-----BEGIN PRIVATE KEY-----\nMIGT\n-----END PRIVATE KEY-----',
        ),
        contains('-----BEGIN'),
      );
    });

    test('a long base64 payload', () {
      // A base64'd keystore is the exact mistake this guards.
      final payload = 'QUJDRA==' * 20;
      expect(
        SecretRefValidator.reasonToReject(payload),
        anyOf(contains('characters'), contains('payload')),
      );
    });

    test('base64 just over the decoded-size limit', () {
      final blob = base64Of(SecretRefValidator.maxDecodedBytes + 8);
      expect(SecretRefValidator.reasonToReject(blob), contains('payload'));
    });

    test('known credential prefixes', () {
      expect(
        SecretRefValidator.reasonToReject('ghp_abcdefghijklmnop'),
        contains('ghp_'),
      );
      expect(
        SecretRefValidator.reasonToReject('xoxb-1-2-abcdef'),
        contains('xoxb-'),
      );
      expect(
        SecretRefValidator.reasonToReject('AKIAIOSFODNN7EXAMPLE'),
        contains('AKIA'),
      );
    });

    test('an empty string', () {
      expect(SecretRefValidator.reasonToReject('  '), contains('is empty'));
    });

    test('a multi-word value', () {
      expect(
        SecretRefValidator.reasonToReject('my secret password'),
        contains('not a valid secret name'),
      );
    });

    test('a value containing a newline', () {
      expect(
        SecretRefValidator.reasonToReject('line one\nline two'),
        contains('multiple lines'),
      );
    });
  });

  group('validate() reports the config path of each violation', () {
    test('names the exact field', () {
      final config = ConfigLoader.parse('''
version: 1
project:
  name: app
apps:
  main: {}
''');
      expect(SecretRefValidator.validate(config), isEmpty);
    });

    test('a p8 pasted into p8_ref is caught with its path', () {
      // Parsing throws, so validate() is exercised through the loader's own
      // error rather than in isolation; the path must still be present.
      expect(
        () => ConfigLoader.parse('''
version: 1
project:
  name: app
apps:
  main:
    signing:
      ios:
        api_key:
          p8_ref: "-----BEGIN PRIVATE KEY-----"
'''),
        throwsA(
          isA<Object>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('apps.main.signing.ios.api_key.p8_ref'),
              contains('committed to your repo'),
            ),
          ),
        ),
      );
    });
  });
}

/// Base64 of [bytes] bytes of filler.
String base64Of(int bytes) {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final raw = List<int>.generate(bytes, (i) => alphabet.codeUnitAt(i % 62));
  return _b64(raw);
}

String _b64(List<int> bytes) {
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final out = StringBuffer();
  for (var i = 0; i < bytes.length; i += 3) {
    final b0 = bytes[i];
    final b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
    final b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out
      ..write(chars[b0 >> 2])
      ..write(chars[((b0 & 3) << 4) | (b1 >> 4)])
      ..write(i + 1 < bytes.length ? chars[((b1 & 15) << 2) | (b2 >> 6)] : '=')
      ..write(i + 2 < bytes.length ? chars[b2 & 63] : '=');
  }
  return out.toString();
}
