import 'package:taxiway/src/cli/commands/build_command.dart';
import 'package:taxiway/src/generators/generated_file.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';

const ResolvedFlavor dev = ResolvedFlavor(
  name: 'dev',
  suffix: '.dev',
  entrypoint: 'lib/main_dev.dart',
  dimension: 'environment',
  iosBundleId: 'com.acme.app.dev',
);

void main() {
  late FixtureProject project;

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
  });

  List<String> argumentsFor({
    BuildArtifact artifact = BuildArtifact.ipa,
    ResolvedFlavor? flavor = dev,
    bool debug = false,
    bool noCodesign = false,
  }) => BuildCommand.buildArguments(
    artifact: artifact,
    flavor: flavor,
    root: project.path,
    debug: debug,
    noCodesign: noCodesign,
  );

  group('the argument list', () {
    test('always passes --target for a flavor', () {
      // The single most important assertion in this file. Without --target,
      // Flutter compiles lib/main.dart under the flavor's bundle id: the wrong
      // app, and the build succeeds. Nothing downstream can detect it.
      final arguments = argumentsFor();
      final index = arguments.indexOf('--target');
      expect(index, isNot(-1), reason: 'no --target in $arguments');
      expect(arguments[index + 1], 'lib/main_dev.dart');
    });

    test('passes the flavor name', () {
      final arguments = argumentsFor();
      expect(arguments[arguments.indexOf('--flavor') + 1], 'dev');
    });

    test('honours a non-conventional entrypoint from the config', () {
      // A project whose `development` flavor uses main_dev.dart is common
      // enough that guessing would build the wrong app under the right id.
      final arguments = BuildCommand.buildArguments(
        artifact: BuildArtifact.ipa,
        flavor: const ResolvedFlavor(
          name: 'development',
          suffix: '.dev',
          entrypoint: 'lib/main_dev.dart',
          dimension: 'environment',
        ),
        root: project.path,
      );
      expect(arguments[arguments.indexOf('--target') + 1], 'lib/main_dev.dart');
    });

    test('adds --dart-define-from-file only when the file exists', () {
      expect(
        argumentsFor(),
        isNot(contains('--dart-define-from-file')),
        reason: 'passing a missing defines file fails the build',
      );

      project.writeJson('dart_defines/dev.json', <String, String>{
        'ENV': 'dev',
      });
      final arguments = argumentsFor();
      expect(
        arguments[arguments.indexOf('--dart-define-from-file') + 1],
        'dart_defines/dev.json',
      );
    });

    test('builds release unless asked for debug', () {
      expect(argumentsFor(), contains('--release'));
      expect(argumentsFor(debug: true), contains('--debug'));
      expect(argumentsFor(debug: true), isNot(contains('--release')));
    });

    test('--no-codesign applies to an archive and nowhere else', () {
      expect(argumentsFor(noCodesign: true), contains('--no-codesign'));
      expect(
        argumentsFor(artifact: BuildArtifact.appbundle, noCodesign: true),
        isNot(contains('--no-codesign')),
      );
    });

    test('a project with no flavors gets no flavor arguments', () {
      final arguments = argumentsFor(flavor: null);
      expect(arguments, <String>['build', 'ipa', '--release']);
    });

    test('names the artifact each platform actually produces', () {
      expect(argumentsFor().first, 'build');
      expect(argumentsFor()[1], 'ipa');
      expect(argumentsFor(artifact: BuildArtifact.appbundle)[1], 'appbundle');
      expect(argumentsFor(artifact: BuildArtifact.apk)[1], 'apk');
    });
  });

  group('artifact paths', () {
    test('match where Flutter actually writes each one', () {
      // Confirmed against a real flavored project during the Phase 2 spike.
      expect(
        BuildCommand.artifactPath(BuildArtifact.appbundle, dev),
        'build/app/outputs/bundle/devRelease/app-dev-release.aab',
      );
      expect(
        BuildCommand.artifactPath(BuildArtifact.apk, dev),
        'build/app/outputs/flutter-apk/app-dev-release.apk',
      );
      expect(
        BuildCommand.artifactPath(BuildArtifact.ipa, dev),
        'build/ios/archive/Runner.xcarchive',
      );
    });

    test('an unflavored project has its own paths', () {
      expect(
        BuildCommand.artifactPath(BuildArtifact.appbundle, null),
        'build/app/outputs/bundle/release/app-release.aab',
      );
    });

    test('the ipa is reported as the archive, never a guessed filename', () {
      // The .ipa is named after CFBundleName under a Flutter export and after
      // the product target under a gym export, so it can only be found by
      // globbing. Pointing at the archive is honest; guessing is not.
      expect(
        BuildCommand.artifactPath(BuildArtifact.ipa, dev),
        isNot(endsWith('.ipa')),
      );
    });
  });
}
