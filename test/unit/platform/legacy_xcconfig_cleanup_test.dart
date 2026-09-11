import 'package:shipway/src/core/managed/content_hash.dart';
import 'package:shipway/src/core/managed/lock_file.dart';
import 'package:shipway/src/platform/ios/legacy_xcconfig_cleanup.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';

void main() {
  late FixtureProject project;
  late LockFile lock;

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
    lock = LockFile(version: LockFile.currentVersion, generatedBy: 'test');
  });

  /// Writes a legacy xcconfig and records it as shipway's own.
  void writeGenerated(String flavor, String contents) {
    final path = LegacyXcconfigCleanup.pathFor(flavor);
    project.write(path, contents);
    lock.record(
      LockEntry(
        path: path,
        ownership: Ownership.generated,
        mode: WriteMode.full,
        hash: ContentHash.of(contents),
      ),
    );
  }

  Future<LegacyXcconfigResult> run(List<String> flavors) =>
      LegacyXcconfigCleanup.run(
        root: project.path,
        lock: lock,
        flavors: flavors,
      );

  test('removes an xcconfig shipway wrote and nobody changed', () async {
    writeGenerated('dev', 'APP_DISPLAY_NAME = Acme Dev\n');

    final result = await run(<String>['dev']);

    expect(result.removed, <String>['ios/Flutter/dev.xcconfig']);
    expect(result.kept, isEmpty);
    expect(project.exists('ios/Flutter/dev.xcconfig'), isFalse);
    // Left in the lockfile it would read as a file shipway still owns.
    expect(lock['ios/Flutter/dev.xcconfig'], isNull);
  });

  test('keeps one the user has edited since', () async {
    writeGenerated('dev', 'APP_DISPLAY_NAME = Acme Dev\n');
    project.write(
      'ios/Flutter/dev.xcconfig',
      'APP_DISPLAY_NAME = Acme Dev\nOTHER_LDFLAGS = -all_load\n',
    );

    final result = await run(<String>['dev']);

    // Deleting a build setting somebody added is far worse than leaving a
    // file that is now referenced by nothing.
    expect(result.removed, isEmpty);
    expect(result.kept, <String>['ios/Flutter/dev.xcconfig']);
    expect(project.exists('ios/Flutter/dev.xcconfig'), isTrue);
  });

  test('keeps one that was never shipway\'s to begin with', () async {
    project.write('ios/Flutter/dev.xcconfig', '#include "Release.xcconfig"\n');

    final result = await run(<String>['dev']);

    expect(result.removed, isEmpty);
    expect(result.kept, <String>['ios/Flutter/dev.xcconfig']);
    expect(project.exists('ios/Flutter/dev.xcconfig'), isTrue);
  });

  test('touches nothing outside the flavors in the config', () async {
    writeGenerated('dev', 'APP_DISPLAY_NAME = Acme Dev\n');
    writeGenerated('staging', 'APP_DISPLAY_NAME = Acme Staging\n');

    final result = await run(<String>['dev']);

    expect(result.removed, <String>['ios/Flutter/dev.xcconfig']);
    expect(project.exists('ios/Flutter/staging.xcconfig'), isTrue);
  });

  test('is silent on a project that never had one', () async {
    final result = await run(<String>['dev', 'prod']);

    expect(result.isEmpty, isTrue);
  });

  test('never touches the stock xcconfigs', () async {
    for (final name in const <String>['Debug', 'Release', 'Generated']) {
      project.write('ios/Flutter/$name.xcconfig', '#include "Generated"\n');
    }
    writeGenerated('dev', 'APP_DISPLAY_NAME = Acme Dev\n');

    await run(<String>['dev', 'Debug', 'Release', 'Generated']);

    for (final name in const <String>['Debug', 'Release', 'Generated']) {
      expect(
        project.exists('ios/Flutter/$name.xcconfig'),
        isTrue,
        reason: '$name.xcconfig',
      );
    }
  });
}
