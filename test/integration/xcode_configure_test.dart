@Tags(<String>['ruby', 'integration'])
// Copying a real Xcode project and running the gem over it is not fast.
@Timeout.factor(10)
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:taxiway/src/core/io/process_runner.dart';
import 'package:taxiway/src/core/io/redactor.dart';
import 'package:taxiway/src/platform/ios/xcode_project_mutator.dart';
import 'package:test/test.dart';

/// A real Flutter iOS project to mutate.
///
/// Set `TAXIWAY_FIXTURE_APP` to an existing `flutter create` app; the project is
/// copied into a temp directory first so the source is never modified.
Future<Directory?> copyFixture() async {
  final source = Platform.environment['TAXIWAY_FIXTURE_APP'];
  if (source == null) return null;
  final xcodeproj = Directory(p.join(source, 'ios/Runner.xcodeproj'));
  if (!xcodeproj.existsSync()) return null;

  final temp = await Directory.systemTemp.createTemp('taxiway_configure');
  final destination = Directory(p.join(temp.path, 'ios/Runner.xcodeproj'));
  await destination.create(recursive: true);
  for (final entity in xcodeproj.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File) continue;
    final relative = p.relative(entity.path, from: xcodeproj.path);
    final target = File(p.join(destination.path, relative));
    await target.parent.create(recursive: true);
    await entity.copy(target.path);
  }
  return temp;
}

void main() {
  late Directory root;
  late ProcessRunner runner;

  setUpAll(() async {
    final copied = await copyFixture();
    if (copied == null) {
      throw StateError(
        'Set TAXIWAY_FIXTURE_APP to a Flutter project with an iOS folder.',
      );
    }
    root = copied;
    runner = SystemProcessRunner(redactor: Redactor());
  });

  tearDownAll(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  XcodeProjectMutator mutator() => XcodeProjectMutator(
    runner: runner,
    scriptPath: 'tool/ruby/xcodeproj_bridge.rb',
    root: root.path,
  );

  List<DesiredConfiguration> devConfigurations() =>
      XcodeProjectMutator.configurationsFor(const <String>[
        'dev',
      ], xcconfigFor: (flavor) => 'Flutter/$flavor.xcconfig');

  Future<Map<String, dynamic>> readProject() async {
    final result = await runner.run('ruby', <String>[
      'tool/ruby/xcodeproj_bridge.rb',
      'read',
      p.join(root.path, 'ios/Runner.xcodeproj'),
    ]);
    return (jsonDecode(result.stdout) as Map<String, dynamic>)['project']
        as Map<String, dynamic>;
  }

  Set<String> configurationNamesOf(Map<String, dynamic> project) {
    final target = (project['targets'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .firstWhere((t) => t['name'] == 'Runner');
    return (target['buildConfigurations'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map((c) => c['name'] as String)
        .toSet();
  }

  test('creates the three configurations a flavor needs', () async {
    final before = configurationNamesOf(await readProject());
    expect(before, isNot(contains('Debug-dev')));

    final result = await mutator().configure(
      configurations: devConfigurations(),
      firebasePlists: <String, String>{
        'Release-dev': 'ios/config/dev/GoogleService-Info.plist',
      },
    );

    expect(result.succeeded, isTrue, reason: result.failureReason);
    expect(result.changed, isTrue);

    final after = configurationNamesOf(await readProject());
    expect(
      after,
      containsAll(<String>['Debug-dev', 'Release-dev', 'Profile-dev']),
    );
    // The originals must survive: taxiway adds configurations, it does not
    // replace the project's own.
    expect(after, containsAll(before));
  });

  test('attaches the flavor xcconfig to the app target', () async {
    await mutator().configure(configurations: devConfigurations());

    final target = (await readProject())['targets'] as List<dynamic>;
    final runnerTarget = target.cast<Map<String, dynamic>>().firstWhere(
      (t) => t['name'] == 'Runner',
    );
    final debugDev = (runnerTarget['buildConfigurations'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .firstWhere((c) => c['name'] == 'Debug-dev');

    expect(debugDev['baseConfigurationReference'], contains('dev.xcconfig'));
  });

  test('adds one named run script phase and updates it in place', () async {
    await mutator().configure(
      configurations: devConfigurations(),
      firebasePlists: <String, String>{
        'Release-dev': 'ios/config/dev/GoogleService-Info.plist',
      },
    );
    await mutator().configure(
      configurations: devConfigurations(),
      firebasePlists: <String, String>{
        'Release-dev': 'ios/config/other/GoogleService-Info.plist',
      },
    );

    final runnerTarget = ((await readProject())['targets'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .firstWhere((t) => t['name'] == 'Runner');
    final ours = (runnerTarget['buildPhases'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .where(
          (phase) => phase['name'] == XcodeProjectMutator.firebasePhaseName,
        )
        .toList();

    // Matched by name so a second run updates rather than appends.
    expect(ours, hasLength(1));
  });

  test('is idempotent: a second run reports no change', () async {
    await mutator().configure(configurations: devConfigurations());
    final pbxproj = File(p.join(root.path, XcodeProjectMutator.pbxprojPath));
    final afterFirst = await pbxproj.readAsString();

    final second = await mutator().configure(
      configurations: devConfigurations(),
    );

    expect(second.succeeded, isTrue);
    expect(second.changed, isFalse);
    // This is what makes `taxiway generate` safe to re-run.
    expect(await pbxproj.readAsString(), afterFirst);
  });

  test(
    'the mutated project is still parseable by Xcode\'s own tooling',
    () async {
      await mutator().configure(configurations: devConfigurations());

      final result = await runner.run('plutil', <String>[
        '-lint',
        p.join(root.path, XcodeProjectMutator.pbxprojPath),
      ]);

      // A corrupt pbxproj is the failure mode that matters most here.
      expect(result.ok, isTrue, reason: result.output);
    },
  );

  test('a backup of the original is kept', () async {
    final result = await mutator().configure(
      configurations: devConfigurations(),
    );

    expect(result.backupPath, isNotNull);
    expect(File(p.join(root.path, result.backupPath!)).existsSync(), isTrue);
  });
}
