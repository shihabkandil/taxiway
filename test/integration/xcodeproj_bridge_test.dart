@Tags(<String>['ruby', 'integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:shipway/src/core/io/process_runner.dart';
import 'package:shipway/src/core/io/redactor.dart';
import 'package:test/test.dart';

/// A Flutter project to read. Set `SHIPWAY_FIXTURE_APP` to reuse one, otherwise
/// the test scaffolds a throwaway app — `flutter create` is slow enough that
/// reusing one locally is worth the flag.
Future<Directory> fixtureApp(ProcessRunner runner) async {
  final existing = Platform.environment['SHIPWAY_FIXTURE_APP'];
  if (existing != null && Directory(existing).existsSync()) {
    return Directory(existing);
  }
  final temp = await Directory.systemTemp.createTemp('shipway_bridge');
  final result = await runner.run('flutter', const <String>[
    'create',
    '--org',
    'com.example',
    '--platforms=ios,android',
    'demo_app',
  ], workingDirectory: temp.path);
  if (!result.ok) {
    throw StateError('flutter create failed: ${result.output}');
  }
  return Directory('${temp.path}/demo_app');
}

void main() {
  // `flutter create` dominates the runtime when no fixture is supplied.
  Timeout.factor(10);

  late ProcessRunner runner;
  late Directory app;

  setUpAll(() async {
    runner = SystemProcessRunner(redactor: Redactor());
    app = await fixtureApp(runner);
  });

  /// Runs the bridge and returns its decoded stdout.
  Future<Map<String, dynamic>> readBridge({String? projectPath}) async {
    final result = await runner.run('ruby', <String>[
      'tool/ruby/xcodeproj_bridge.rb',
      'read',
      projectPath ?? '${app.path}/ios/Runner.xcodeproj',
    ]);
    // The contract is that stdout is always a JSON object, success or failure,
    // so a caller never has to guess whether to parse it.
    return jsonDecode(result.stdout) as Map<String, dynamic>;
  }

  group('read op', () {
    test('returns the project as JSON', () async {
      final response = await readBridge();
      expect(response['ok'], isTrue, reason: '${response['error']}');
      expect(response['bridgeVersion'], 1);
      expect(response['xcodeprojVersion'], isA<String>());

      final project = response['project'] as Map<String, dynamic>;
      expect(project['objectVersion'], isA<int>());
      expect(project['synchronizedRootGroups'], isA<List<dynamic>>());
    });

    test(
      'reports the Runner target with Flutter\'s three configurations',
      () async {
        final project = (await readBridge())['project'] as Map<String, dynamic>;
        final targets = (project['targets'] as List<dynamic>)
            .cast<Map<String, dynamic>>();

        final runnerTarget = targets.firstWhere((t) => t['name'] == 'Runner');
        expect(runnerTarget['type'], 'com.apple.product-type.application');

        final configs = (runnerTarget['buildConfigurations'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        // Flutter requires exactly these three names; flavors extend them as
        // `<Config>-<flavor>`, which is what the iOS inspector keys off.
        expect(
          configs.map((c) => c['name']),
          containsAll(<String>['Debug', 'Release', 'Profile']),
        );
      },
    );

    test('exposes PRODUCT_BUNDLE_IDENTIFIER per configuration', () async {
      final project = (await readBridge())['project'] as Map<String, dynamic>;
      final runnerTarget = (project['targets'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .firstWhere((t) => t['name'] == 'Runner');

      final configurations =
          (runnerTarget['buildConfigurations'] as List<dynamic>)
              .cast<Map<String, dynamic>>();

      // Read from the fixture rather than hardcoded, so pointing
      // SHIPWAY_FIXTURE_APP at any `flutter create` app still exercises this.
      final expected =
          (configurations.first['buildSettings']
              as Map<String, dynamic>)['PRODUCT_BUNDLE_IDENTIFIER'];
      expect(expected, isA<String>().having((s) => s, 'id', contains('.')));

      for (final config in configurations) {
        final settings = config['buildSettings'] as Map<String, dynamic>;
        expect(
          settings['PRODUCT_BUNDLE_IDENTIFIER'],
          expected,
          reason: 'configuration ${config['name']}',
        );
      }
    });

    test(
      'follows the xcconfig chain, where a flavor bundle id often lives',
      () async {
        final project = (await readBridge())['project'] as Map<String, dynamic>;
        final runnerTarget = (project['targets'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .firstWhere((t) => t['name'] == 'Runner');
        final debug = (runnerTarget['buildConfigurations'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .firstWhere((c) => c['name'] == 'Debug');

        expect(debug['baseConfigurationReference'], endsWith('Debug.xcconfig'));
      },
    );

    test(
      'reports shell script phases so an existing flavor setup is visible',
      () async {
        final project = (await readBridge())['project'] as Map<String, dynamic>;
        final runnerTarget = (project['targets'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .firstWhere((t) => t['name'] == 'Runner');
        final phases = (runnerTarget['buildPhases'] as List<dynamic>)
            .cast<Map<String, dynamic>>();

        final scripts = phases
            .where((p) => p['isa'] == 'PBXShellScriptBuildPhase')
            .toList();
        expect(scripts, isNotEmpty);
        // Overwriting a phase that copies a per-flavor GoogleService-Info.plist
        // would silently break Firebase, so the reader must see the script body.
        expect(scripts.first['shellScript'], isA<String>());
      },
    );
  });

  group('failure contract', () {
    test('a missing project is a JSON error, not a Ruby backtrace', () async {
      final response = await readBridge(projectPath: '/nope/Missing.xcodeproj');
      expect(response['ok'], isFalse);
      final error = response['error'] as Map<String, dynamic>;
      expect(error['code'], 'project_missing');
      expect(error['message'], contains('/nope/Missing.xcodeproj'));
    });

    test('an unknown op is rejected by name', () async {
      final result = await runner.run('ruby', <String>[
        'tool/ruby/xcodeproj_bridge.rb',
        'demolish',
        '${app.path}/ios/Runner.xcodeproj',
      ]);
      final response = jsonDecode(result.stdout) as Map<String, dynamic>;
      expect(response['ok'], isFalse);
      expect((response['error'] as Map<String, dynamic>)['code'], 'unknown_op');
      expect(result.exitCode, isNot(0));
    });
  });
}
