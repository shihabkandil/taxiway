import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shipway/src/core/io/process_runner.dart';
import 'package:shipway/src/core/io/redactor.dart';
import 'package:shipway/src/platform/ios/match_repository.dart';
import 'package:test/test.dart';

void main() {
  group('reading a profile path', () {
    MatchProfile? parse(String path) => MatchRepository.parseProfilePath(path);

    test('every type match writes', () {
      // Prefixes taken from Match::Generator.profile_type_name.
      const cases = <String, String>{
        'appstore/AppStore_com.acme.app.mobileprovision': 'appstore',
        'development/Development_com.acme.app.mobileprovision': 'development',
        'adhoc/AdHoc_com.acme.app.mobileprovision': 'adhoc',
        'enterprise/InHouse_com.acme.app.mobileprovision': 'enterprise',
        'developer_id/Direct_com.acme.app.provisionprofile': 'developer_id',
      };
      for (final entry in cases.entries) {
        final profile = parse(entry.key);
        expect(profile?.type, entry.value, reason: entry.key);
        expect(profile?.bundleId, 'com.acme.app', reason: entry.key);
      }
    });

    test('a bundle id containing the separator survives', () {
      // Matched against the known prefixes rather than split on the first
      // underscore, so an id that contains one is not truncated.
      expect(
        parse('appstore/AppStore_com.acme.my_app.mobileprovision')?.bundleId,
        'com.acme.my_app',
      );
    });

    test('the directory wins over the prefix if they disagree', () {
      // The directory is what match actually looks in.
      expect(
        parse('adhoc/AppStore_com.acme.app.mobileprovision')?.type,
        'adhoc',
      );
    });

    test('anything that is not a profile is ignored, not misread', () {
      for (final path in const <String>[
        'appstore/README.md',
        'appstore/AppStore_.mobileprovision',
        'appstore/something.mobileprovision',
        'AppStore_com.acme.app.mobileprovision',
        'appstore/AppStore_com.acme.app.txt',
      ]) {
        expect(parse(path), isNull, reason: path);
      }
    });
  });

  group('against a real repository on disk', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('shipway_match_test');
      addTearDown(() async {
        if (root.existsSync()) await root.delete(recursive: true);
      });

      void write(String relative) {
        final file = File(
          p.join(root.path, p.joinAll(p.posix.split(relative))),
        );
        file.parent.createSync(recursive: true);
        // match encrypts contents in place and leaves names alone, which is
        // exactly why the contents here can be nonsense.
        file.writeAsStringSync('ENCRYPTED');
      }

      write('certs/distribution/ABC123.cer');
      write('certs/distribution/ABC123.p12');
      write('profiles/appstore/AppStore_com.acme.app.mobileprovision');
      write('profiles/appstore/AppStore_com.acme.app.dev.mobileprovision');
      write('profiles/development/Development_com.acme.app.mobileprovision');
    });

    test('reports what is there', () {
      final contents = MatchRepository.readDirectory(root);
      expect(contents.isEmpty, isFalse);
      expect(contents.certificateTypes, <String>{'distribution'});
      expect(contents.bundleIdsFor('appstore'), <String>{
        'com.acme.app',
        'com.acme.app.dev',
      });
      expect(contents.bundleIdsFor('development'), <String>{'com.acme.app'});
    });

    test('names exactly what a config asks for and does not have', () {
      final contents = MatchRepository.readDirectory(root);
      expect(
        contents.missingFrom(const <String>[
          'com.acme.app',
          'com.acme.app.staging',
        ], 'appstore'),
        <String>['com.acme.app.staging'],
      );
    });

    test('a development profile does not cover an App Store build', () {
      // A repository full of development profiles does not make a release
      // signable, and reporting it as coverage would be worse than silence.
      final contents = MatchRepository.readDirectory(root);
      expect(
        contents.missingFrom(const <String>['com.acme.app'], 'adhoc'),
        <String>['com.acme.app'],
      );
    });

    test('an empty repository is empty, not an error', () async {
      final bare = await Directory.systemTemp.createTemp('shipway_match_bare');
      addTearDown(() async => bare.delete(recursive: true));
      expect(MatchRepository.readDirectory(bare).isEmpty, isTrue);
    });

    test('a certs directory with no files does not count as covered', () {
      Directory(p.join(root.path, 'certs', 'development')).createSync();
      expect(MatchRepository.readDirectory(root).certificateTypes, <String>{
        'distribution',
      });
    });
  });

  group('cloning', () {
    // Tagged because it shells out to git.
    late Directory origin;

    setUp(() async {
      origin = await Directory.systemTemp.createTemp('shipway_match_origin');
      addTearDown(() async {
        if (origin.existsSync()) await origin.delete(recursive: true);
      });
    });

    test('reads a real git repository', () async {
      final file = File(
        p.join(
          origin.path,
          'profiles',
          'appstore',
          'AppStore_com.acme.app.mobileprovision',
        ),
      );
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('ENCRYPTED');

      Future<void> git(List<String> args) async {
        final result = await Process.run(
          'git',
          args,
          workingDirectory: origin.path,
        );
        expect(
          result.exitCode,
          0,
          reason: '${args.join(' ')}: ${result.stderr}',
        );
      }

      await git(<String>['init', '-q', '-b', 'main', '.']);
      await git(<String>['add', '-A']);
      await git(<String>[
        '-c',
        'user.email=t@t',
        '-c',
        'user.name=t',
        'commit',
        '-qm',
        'certs',
      ]);

      final contents = await MatchRepository.read(
        gitUrl: origin.path,
        runner: SystemProcessRunner(redactor: Redactor()),
        branch: 'main',
      );
      expect(contents.bundleIdsFor('appstore'), <String>{'com.acme.app'});
    }, tags: <String>['integration']);
  });
}
