import 'package:shipway/src/platform/ios/info_plist_mutator.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';
import '../../support/recording_process_runner.dart';

void main() {
  late RecordingProcessRunner runner;
  late FixtureProject project;

  setUp(() async {
    runner = RecordingProcessRunner();
    project = await FixtureProject.create();
    addTearDown(project.dispose);
    project
      ..withPubspec()
      ..withIosProject(displayName: 'Demo App');
  });

  InfoPlistMutator mutator() =>
      InfoPlistMutator(runner: runner, root: project.path);

  group('reading', () {
    test('returns the current display name', () async {
      stubPlutil(runner);
      expect(await mutator().readDisplayName(), 'Demo App');
    });

    test('uses plutil rather than parsing the plist ourselves', () async {
      stubPlutil(runner);
      await mutator().readDisplayName();

      final invocation = runner.invocation('-extract');
      expect(invocation.executable, 'plutil');
      expect(
        invocation.arguments,
        containsAllInOrder(<String>['-extract', 'CFBundleDisplayName', 'raw']),
      );
    });

    test('reports not-configured before, and configured after', () async {
      stubPlutil(runner);
      expect(await mutator().isConfigured(), isFalse);

      await mutator().pointDisplayNameAtBuildSetting();

      expect(await mutator().isConfigured(), isTrue);
    });
  });

  group('pointing the plist at the build setting', () {
    test('replaces the literal with the reference', () async {
      stubPlutil(runner);

      final result = await mutator().pointDisplayNameAtBuildSetting();

      expect(result.succeeded, isTrue);
      expect(result.changed, isTrue);
      final invocation = runner.invocation('-replace');
      expect(
        invocation.arguments,
        containsAllInOrder(<String>[
          '-replace',
          'CFBundleDisplayName',
          '-string',
          r'$(APP_DISPLAY_NAME)',
        ]),
      );
    });

    test('reports the previous literal so it can be preserved', () async {
      stubPlutil(runner);

      final result = await mutator().pointDisplayNameAtBuildSetting();

      // The caller must define APP_DISPLAY_NAME for the unflavored build types
      // using this, or those builds ship with an empty name.
      expect(result.previousValue, 'Demo App');
    });

    test('backs the plist up first', () async {
      stubPlutil(runner);

      final result = await mutator().pointDisplayNameAtBuildSetting();

      expect(result.backupPath, startsWith('.shipway/backups/'));
      expect(project.read(result.backupPath!), contains('Demo App'));
    });

    test('is a no-op once already configured', () async {
      stubPlutil(runner, currentDisplayName: r'$(APP_DISPLAY_NAME)');

      final result = await mutator().pointDisplayNameAtBuildSetting();

      expect(result.succeeded, isTrue);
      expect(result.changed, isFalse);
      expect(runner.ran('-replace'), isFalse, reason: 'nothing to do');
      expect(result.backupPath, isNull);
    });
  });

  group('failures restore the original', () {
    test('a plutil error puts the file back', () async {
      stubPlutil(runner);
      runner.stub(
        'plutil -replace',
        exitCode: 1,
        stderr: 'Info.plist: Property List error',
      );

      final result = await mutator().pointDisplayNameAtBuildSetting();

      expect(result.succeeded, isFalse);
      expect(result.restored, isTrue);
      expect(project.read(InfoPlistMutator.plistPath), contains('Demo App'));
      expect(result.failureRemedy, contains('plutil -lint'));
    });

    test('a missing plutil is reported plainly', () async {
      stubPlutil(runner);
      runner.stub('plutil -replace', exitCode: 127);

      final result = await mutator().pointDisplayNameAtBuildSetting();

      expect(result.failureReason, contains('plutil'));
      expect(result.restored, isTrue);
    });

    test(
      'an edit that silently did not apply is caught and reverted',
      () async {
        // plutil exits 0 but the key is unchanged. Trusting the exit code here
        // would leave every flavor sharing one name, and look like success.
        runner
          ..stub('plutil -extract', stdout: 'Demo App')
          ..stub('plutil -replace');

        final result = await mutator().pointDisplayNameAtBuildSetting();

        expect(result.succeeded, isFalse);
        expect(result.failureReason, contains('still does not reference'));
        expect(result.restored, isTrue);
        expect(project.read(InfoPlistMutator.plistPath), contains('Demo App'));
      },
    );

    test(
      'a project with no Info.plist fails before running anything',
      () async {
        final bare = await FixtureProject.create();
        addTearDown(bare.dispose);
        bare.withPubspec();

        final result = await InfoPlistMutator(
          runner: runner,
          root: bare.path,
        ).pointDisplayNameAtBuildSetting();

        expect(result.succeeded, isFalse);
        expect(result.failureRemedy, contains('flutter create'));
        expect(runner.invocations, isEmpty);
      },
    );
  });
}
