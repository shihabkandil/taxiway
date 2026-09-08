import 'dart:io';

import 'package:taxiway/src/core/config/config_exception.dart';
import 'package:taxiway/src/core/config/config_loader.dart';
import 'package:taxiway/src/core/config/taxiway_config.dart';
import 'package:test/test.dart';

String _fixture(String name) =>
    File('test/fixtures/config/$name').readAsStringSync();

/// Asserts that [name] fails to load and that the message says something a user
/// can act on. Each invalid fixture pins its own message so a refactor cannot
/// quietly degrade a good error into a generic one.
void expectInvalid(String name, Matcher messageMatcher) {
  test(name, () {
    ConfigException? thrown;
    try {
      ConfigLoader.parse(_fixture('invalid/$name'), path: name);
    } on ConfigException catch (e) {
      thrown = e;
    }
    expect(thrown, isNotNull, reason: '$name should not have parsed');
    expect(thrown.toString(), messageMatcher);
  });
}

void main() {
  group('valid configs', () {
    test('minimal parses with sensible defaults', () {
      final config = ConfigLoader.parse(_fixture('minimal.yaml'));
      expect(config.version, 1);
      expect(config.project.name, 'minimal_app');
      expect(config.project.pubspec, 'pubspec.yaml');
      expect(config.project.flutterMin, isNull);
      expect(config.defaultAppId, 'main');
      final app = config.appOrNull(null)!;
      expect(app.path, '.');
      expect(app.flavors, isEmpty);
      expect(app.versioning.strategy, VersioningStrategy.increment);
      expect(app.versioning.syncIosAndroid, isTrue);
      expect(config.secrets.dotenv, '.env.{flavor}');
      expect(config.secrets.keychain, isTrue);
    });

    test('full config parses every documented field', () {
      final config = ConfigLoader.parse(_fixture('full.yaml'));
      final app = config.apps['main']!;

      expect(config.project.flutterMin, '3.35.0');
      expect(app.flavors.keys, ['dev', 'prod']);

      final dev = app.flavors['dev']!;
      expect(dev.suffix, '.dev');
      expect(dev.displayName, 'Acme Dev');
      expect(dev.dartDefines, {'ENV': 'dev', 'API': 'https://dev.api'});
      expect(dev.icon, 'assets/icon/dev.png');
      expect(dev.firebase!.android,
          'android/app/src/dev/google-services.json');

      expect(app.signing.ios!.teamId, 'ABCDE12345');
      expect(app.signing.ios!.matchStorage, MatchStorage.git);
      expect(app.signing.ios!.apiKey!.p8Ref, 'ASC_KEY_P8_BASE64');
      expect(app.signing.android!.keyProperties!.keyAlias, 'upload');

      expect(app.targets.testflight!.groups, ['internal', 'qa']);
      expect(app.targets.testflight!.changelogFrom, ChangelogSource.git);
      expect(app.targets.play!.releaseStatus, PlayReleaseStatus.inProgress);
      expect(app.targets.play!.rollout, 0.1);
      expect(app.targets.play!.artifact, PlayArtifact.aab);
      expect(app.targets.firebase!.groups, ['testers']);
      expect(app.versioning.strategy, VersioningStrategy.remote);
      expect(config.notify.slackWebhookRef, 'SLACK_WEBHOOK');
    });

    test('an empty flavor entry takes all defaults', () {
      final config = ConfigLoader.parse('''
version: 1
project:
  name: app
apps:
  main:
    flavors:
      prod:
''');
      expect(config.apps['main']!.flavors['prod']!.suffix, '');
    });

    test('a single non-main app is the default app', () {
      final config = ConfigLoader.parse('''
version: 1
project:
  name: app
apps:
  only:
    path: .
''');
      expect(config.defaultAppId, 'only');
    });

    test('survives a JSON round-trip', () {
      final original = ConfigLoader.parse(_fixture('full.yaml'));
      final again = TaxiwayConfig.fromJson(original.toJson());
      expect(again.toJson(), equals(original.toJson()));
    });
  });

  group('invalid configs each report an actionable message', () {
    expectInvalid('unknown_key.yaml', contains('flavour_min'));
    expectInvalid('missing_project_name.yaml', contains('name'));
    expectInvalid('bad_version.yaml', contains('Unsupported config version 99'));
    expectInvalid('no_apps.yaml', contains('`apps` is empty'));
    expectInvalid('ambiguous_apps.yaml', contains('none is named `main`'));
    expectInvalid('duplicate_suffix.yaml', contains('both use suffix ".dev"'));
    expectInvalid('bad_flavor_name.yaml', contains('`dev-eu`'));
    expectInvalid('secret_in_ref.yaml', contains('-----BEGIN'));
    expectInvalid(
      'rollout_without_in_progress.yaml',
      contains('requires `release_status: inProgress`'),
    );
    expectInvalid('rollout_out_of_range.yaml', contains('between 0'));
    expectInvalid('bad_enum.yaml', contains('track'));
    expectInvalid('malformed_yaml.yaml', contains('malformed_yaml.yaml:'));

    test('an empty file is rejected with a next step', () {
      expect(
        () => ConfigLoader.parse(''),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.toString(),
            'message',
            contains('taxiway import'),
          ),
        ),
      );
    });
  });

  group('error locations', () {
    test('a schema error carries a line number', () {
      ConfigException? thrown;
      try {
        ConfigLoader.parse(
          _fixture('invalid/unknown_key.yaml'),
          path: 'taxiway.yaml',
        );
      } on ConfigException catch (e) {
        thrown = e;
      }
      expect(thrown!.line, isNotNull);
      expect(thrown.location, startsWith('taxiway.yaml:'));
    });
  });

  group('ConfigLoader.locate', () {
    test('finds taxiway.yaml and returns null when absent', () async {
      final dir = await Directory.systemTemp.createTemp('taxiway_cfg');
      addTearDown(() => dir.delete(recursive: true));
      expect(ConfigLoader.locate(dir.path), isNull);
      File('${dir.path}/taxiway.yaml').writeAsStringSync('version: 1');
      expect(ConfigLoader.locate(dir.path), isNotNull);
    });
  });
}
