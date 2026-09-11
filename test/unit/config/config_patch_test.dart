import 'package:shipway/src/core/config/config_loader.dart';
import 'package:shipway/src/core/config/config_patch.dart';
import 'package:test/test.dart';

const String _config = '''
version: 1
project:
  name: acme_app
apps:
  main:
    path: .
    # Two flavors, because staging is where QA lives.
    flavors:
      prod:
        suffix: ""
''';

void main() {
  test('an existing value is replaced in place', () {
    final patched = ConfigPatch.set(_config, <String>[
      'project',
      'name',
    ], 'renamed');

    expect(ConfigLoader.parse(patched).project.name, 'renamed');
  });

  test('comments and ordering survive', () {
    // The reason this exists rather than re-rendering the file: a config a
    // team has edited carries decisions a regeneration throws away without
    // asking.
    final patched = ConfigPatch.set(_config, <String>[
      'apps',
      'main',
      'signing',
      'android',
      'keystore_ref',
    ], 'ANDROID_KEYSTORE_BASE64');

    expect(patched, contains('# Two flavors, because staging is where QA'));
    expect(patched.indexOf('version:'), lessThan(patched.indexOf('project:')));
  });

  test('missing parents are created rather than refused', () {
    // A project that has never declared `signing:` is the normal case for a
    // setup command, not an edge one.
    final patched = ConfigPatch.set(_config, <String>[
      'apps',
      'main',
      'signing',
      'android',
      'keystore_ref',
    ], 'ANDROID_KEYSTORE_BASE64');

    final config = ConfigLoader.parse(patched);
    expect(
      config.apps['main']!.signing.android!.keystoreRef,
      'ANDROID_KEYSTORE_BASE64',
    );
  });

  test('several paths apply in one pass', () {
    final patched = ConfigPatch.setAll(_config, <List<String>, Object?>{
      <String>['apps', 'main', 'signing', 'android', 'keystore_ref']:
          'ANDROID_KEYSTORE_BASE64',
      <String>[
        'apps',
        'main',
        'signing',
        'android',
        'key_properties',
        'key_alias',
      ]: 'upload',
    });

    final android = ConfigLoader.parse(patched).apps['main']!.signing.android!;
    expect(android.keystoreRef, 'ANDROID_KEYSTORE_BASE64');
    expect(android.keyProperties!.keyAlias, 'upload');
  });

  test('the result is still a config shipway can read', () {
    // A patcher that produced valid YAML but an invalid config would be worse
    // than one that refused: the failure lands on the next command.
    final patched = ConfigPatch.set(_config, <String>[
      'apps',
      'main',
      'signing',
      'ios',
      'team_id',
    ], 'ABCDE12345');

    expect(
      ConfigLoader.parse(patched).apps['main']!.signing.ios!.teamId,
      'ABCDE12345',
    );
  });

  test('a created branch is block style, like the rest of the file', () {
    // Flow style — `signing: {android: {keystore_ref: X}}` — is valid YAML and
    // unlike every other line in the file, which makes the next hand edit
    // worse for no reason.
    final patched = ConfigPatch.set(_config, <String>[
      'apps',
      'main',
      'signing',
      'android',
      'keystore_ref',
    ], 'ANDROID_KEYSTORE_BASE64');

    expect(patched, isNot(contains('{')));
    expect(patched, contains('    signing:\n      android:\n'));
  });
}
