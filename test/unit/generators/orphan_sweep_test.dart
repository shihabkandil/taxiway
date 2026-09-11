import 'package:shipway/src/core/managed/content_hash.dart';
import 'package:shipway/src/core/managed/lock_file.dart';
import 'package:shipway/src/core/model/android_model.dart';
import 'package:shipway/src/generators/dart_generators.dart';
import 'package:shipway/src/generators/fastlane_generators.dart';
import 'package:shipway/src/generators/generated_file.dart';
import 'package:shipway/src/generators/ios_generators.dart';
import 'package:shipway/src/generators/orphan_sweep.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';

ResolvedApp appWith({
  List<String> flavors = const <String>['dev'],
  String? schemeTemplate = '<Scheme/>',
}) => ResolvedApp(
  appId: 'main',
  projectName: 'acme_app',
  androidApplicationId: 'com.acme.app',
  iosBundleId: 'com.acme.app',
  gradleDsl: GradleDsl.kotlin,
  iosSchemeTemplate: schemeTemplate,
  flavors: <ResolvedFlavor>[
    for (final name in flavors)
      ResolvedFlavor(
        name: name,
        suffix: '.$name',
        entrypoint: 'lib/main_$name.dart',
        dimension: 'environment',
        iosBundleId: 'com.acme.app.$name',
      ),
  ],
);

void main() {
  late FixtureProject project;
  late LockFile lock;

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
    lock = LockFile(version: LockFile.currentVersion, generatedBy: 'test');
  });

  /// Writes a file and records it as shipway's own, unedited.
  void generated(String path, String contents) {
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

  Future<SweepReport> sweep({
    required List<Generator> generators,
    required Iterable<String> produced,
    ResolvedApp? app,
    int appCount = 1,
    bool dryRun = false,
    bool enabled = true,
  }) => OrphanSweep.run(
    root: project.path,
    lock: lock,
    app: app ?? appWith(),
    generators: generators,
    produced: produced,
    appCount: appCount,
    dryRun: dryRun,
    enabled: enabled,
  );

  group('a renamed flavor', () {
    test('its entrypoint and defines are removed', () async {
      generated('lib/main_dev.dart', 'void main() {}\n');
      generated('dart_defines/dev.json', '{}\n');
      generated('lib/main_development.dart', 'void main() {}\n');
      generated('dart_defines/development.json', '{}\n');

      final report = await sweep(
        generators: const <Generator>[
          DartEntrypointGenerator(),
          DartDefinesGenerator(),
        ],
        produced: const <String>[
          'lib/main_development.dart',
          'dart_defines/development.json',
        ],
      );

      expect(report.results.map((r) => r.path), <String>[
        'dart_defines/dev.json',
        'lib/main_dev.dart',
      ]);
      expect(project.exists('lib/main_dev.dart'), isFalse);
      expect(project.exists('dart_defines/dev.json'), isFalse);
      // The live ones are untouched.
      expect(project.exists('lib/main_development.dart'), isTrue);
      expect(lock['lib/main_dev.dart'], isNull);
    });
  });

  group('what it refuses to delete', () {
    test('a file the user has edited is released, not removed', () async {
      generated('lib/main_dev.dart', 'void main() {}\n');
      project.write('lib/main_dev.dart', 'void main() { realWork(); }\n');

      final report = await sweep(
        generators: const <Generator>[DartEntrypointGenerator()],
        produced: const <String>[],
      );

      expect(report.results.single.outcome, OrphanOutcome.released);
      expect(project.exists('lib/main_dev.dart'), isTrue);
      // Handed back rather than kept as a claim, so it is reported once and
      // never again.
      expect(lock.ownershipOf('lib/main_dev.dart'), Ownership.unmanaged);
    });

    test('a file with no recorded hash is released, not removed', () async {
      // Not knowing what we wrote is not evidence that nothing was written.
      project.write('lib/main_dev.dart', 'void main() {}\n');
      lock.record(
        const LockEntry(
          path: 'lib/main_dev.dart',
          ownership: Ownership.generated,
          mode: WriteMode.full,
        ),
      );

      final report = await sweep(
        generators: const <Generator>[DartEntrypointGenerator()],
        produced: const <String>[],
      );

      expect(report.results.single.outcome, OrphanOutcome.released);
      expect(project.exists('lib/main_dev.dart'), isTrue);
    });

    test('an adopted file is never a candidate', () async {
      project.write('lib/main_dev.dart', 'void main() {}\n');
      lock.record(
        const LockEntry(
          path: 'lib/main_dev.dart',
          ownership: Ownership.adopted,
          mode: WriteMode.full,
        ),
      );

      final report = await sweep(
        generators: const <Generator>[DartEntrypointGenerator()],
        produced: const <String>[],
      );

      expect(report.results, isEmpty);
      expect(project.exists('lib/main_dev.dart'), isTrue);
    });

    test(
      'lib/main.dart and main_common.dart are outside the territory',
      () async {
        // main.dart is the project's own; main_common.dart is create-once
        // scaffolding that holds the user's setup.
        generated('lib/main.dart', 'void main() {}\n');
        generated(DartEntrypointGenerator.commonPath, 'void bootstrap() {}\n');

        final report = await sweep(
          generators: const <Generator>[DartEntrypointGenerator()],
          produced: const <String>[],
        );

        expect(report.results, isEmpty);
        expect(project.exists('lib/main.dart'), isTrue);
        expect(project.exists(DartEntrypointGenerator.commonPath), isTrue);
      },
    );
  });

  group('absence is not evidence of removal', () {
    test('a partial run does not sweep another generator territory', () async {
      // `shipway generate flavors` produces no fastlane files. The naive rule
      // would delete the whole fastlane setup.
      generated('ios/fastlane/Matchfile', 'git_url("x")\n');
      generated('lib/main_dev.dart', 'void main() {}\n');

      final report = await sweep(
        generators: const <Generator>[DartEntrypointGenerator()],
        produced: const <String>['lib/main_dev.dart'],
      );

      expect(report.results, isEmpty);
      expect(project.exists('ios/fastlane/Matchfile'), isTrue);
    });

    test('a generator that could not run sweeps nothing', () async {
      // No Runner.xcscheme to derive from, so IosSchemeGenerator produces
      // nothing — but because it *cannot*, not because the config changed.
      generated(
        '${IosSchemeGenerator.schemeDirectory}/dev.xcscheme',
        '<Scheme/>\n',
      );

      final report = await sweep(
        generators: const <Generator>[IosSchemeGenerator()],
        produced: const <String>[],
        app: appWith(schemeTemplate: null),
      );

      expect(report.results, isEmpty);
      expect(
        project.exists('${IosSchemeGenerator.schemeDirectory}/dev.xcscheme'),
        isTrue,
        reason: 'a missing template must not delete working schemes',
      );
    });

    test('Runner.xcscheme is never swept', () async {
      generated(
        '${IosSchemeGenerator.schemeDirectory}/Runner.xcscheme',
        '<Scheme/>\n',
      );

      final report = await sweep(
        generators: const <Generator>[IosSchemeGenerator()],
        produced: const <String>[],
      );

      expect(report.results, isEmpty);
    });

    test('a monorepo is skipped and says so', () async {
      generated('lib/main_dev.dart', 'void main() {}\n');

      final report = await sweep(
        generators: const <Generator>[DartEntrypointGenerator()],
        produced: const <String>[],
        appCount: 2,
      );

      expect(report.skipped, SweepSkipReason.monorepo);
      expect(report.results, isEmpty);
      expect(project.exists('lib/main_dev.dart'), isTrue);
    });

    test('--no-prune skips everything', () async {
      generated('lib/main_dev.dart', 'void main() {}\n');

      final report = await sweep(
        generators: const <Generator>[DartEntrypointGenerator()],
        produced: const <String>[],
        enabled: false,
      );

      expect(report.skipped, SweepSkipReason.disabled);
      expect(project.exists('lib/main_dev.dart'), isTrue);
    });
  });

  group('switching the export shape', () {
    test('sweeps the ExportOptions plists nothing reads any more', () async {
      generated('ios/ExportOptions-dev.plist', '<plist/>\n');

      final report = await sweep(
        generators: const <Generator>[ExportOptionsGenerator()],
        produced: const <String>[],
      );

      expect(report.results.single.outcome, OrphanOutcome.removed);
      expect(project.exists('ios/ExportOptions-dev.plist'), isFalse);
    });
  });

  group('--dry-run', () {
    test('reports what would happen and changes nothing', () async {
      generated('lib/main_dev.dart', 'void main() {}\n');
      generated('dart_defines/dev.json', '{}\n');
      project.write('dart_defines/dev.json', '{"EDITED": true}\n');

      final report = await sweep(
        generators: const <Generator>[
          DartEntrypointGenerator(),
          DartDefinesGenerator(),
        ],
        produced: const <String>[],
        dryRun: true,
      );

      expect(report.results.map((r) => r.outcome), <OrphanOutcome>[
        OrphanOutcome.wouldRelease,
        OrphanOutcome.wouldRemove,
      ]);
      expect(project.exists('lib/main_dev.dart'), isTrue);
      expect(project.exists('dart_defines/dev.json'), isTrue);
      expect(lock.ownershipOf('lib/main_dev.dart'), Ownership.generated);
    });
  });

  test('a lock entry whose file is already gone is just forgotten', () async {
    lock.record(
      LockEntry(
        path: 'lib/main_dev.dart',
        ownership: Ownership.generated,
        mode: WriteMode.full,
        hash: ContentHash.of('x'),
      ),
    );

    final report = await sweep(
      generators: const <Generator>[DartEntrypointGenerator()],
      produced: const <String>[],
    );

    expect(report.results, isEmpty, reason: 'nothing to report; it was gone');
    expect(lock['lib/main_dev.dart'], isNull);
  });
}
