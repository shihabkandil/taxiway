import 'package:taxiway/src/core/model/uncertainty.dart';
import 'package:taxiway/src/inspect/ios_inspector.dart';
import 'package:taxiway/src/inspect/xcodeproj_bridge.dart';
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
  });

  Future<IosInspectResult> inspect() => IosInspector(
        bridge: XcodeprojBridge(
          runner: runner,
          scriptPath: 'tool/ruby/xcodeproj_bridge.rb',
        ),
      ).inspect(project.path);

  List<Uncertainty> defectsOf(IosInspectResult result) => result.uncertainties
      .where((u) => u.severity == UncertaintySeverity.defect)
      .toList();

  group('a well-formed flavored project', () {
    setUp(() {
      project
        ..withPubspec()
        ..withIosProject()
        ..withSharedScheme('dev',
            launch: 'Debug-dev', archive: 'Release-dev')
        ..withSharedScheme('prod',
            launch: 'Debug-prod', archive: 'Release-prod');
      stubBridge(
        runner,
        stubBridgeJson(
          configurations: <String, String>{
            'Debug': 'com.acme.app',
            'Release': 'com.acme.app',
            'Profile': 'com.acme.app',
            'Debug-dev': 'com.acme.app.dev',
            'Release-dev': 'com.acme.app.dev',
            'Profile-dev': 'com.acme.app.dev',
            'Debug-prod': 'com.acme.app',
            'Release-prod': 'com.acme.app',
            'Profile-prod': 'com.acme.app',
          },
        ),
      );
    });

    test('reads configurations, bundle ids and the team', () async {
      final result = await inspect();
      final target = result.ios.applicationTarget!;
      expect(target.name, 'Runner');
      expect(
        target.buildConfigurations['Release-dev']!.bundleIdentifier,
        'com.acme.app.dev',
      );
      expect(
        target.buildConfigurations['Release']!.developmentTeam,
        'ABCDE12345',
      );
    });

    test('reads shared schemes with their launch and archive configurations',
        () async {
      final result = await inspect();
      final dev = result.ios.schemes['dev']!;
      expect(dev.shared, isTrue);
      expect(dev.buildConfiguration, 'Debug-dev');
      expect(dev.archiveConfiguration, 'Release-dev');
    });

    test('reports no defects', () async {
      expect(defectsOf(await inspect()), isEmpty);
    });
  });

  group('planted defects are reported, not silently dropped', () {
    test('a mis-cased build type names the exact rename', () async {
      project
        ..withPubspec()
        ..withIosProject()
        ..withSharedScheme('dev',
            launch: 'debug-dev', archive: 'release-dev');
      stubBridge(
        runner,
        stubBridgeJson(
          configurations: <String, String>{
            'Debug': 'com.acme.app',
            'Release': 'com.acme.app',
            'Profile': 'com.acme.app',
            // Flutter matches `<BuildType>-<flavor>` case-sensitively, so a
            // lower-cased build type simply does not work.
            'release-dev': 'com.acme.app.dev',
            'debug-dev': 'com.acme.app.dev',
          },
        ),
      );

      final casing = defectsOf(await inspect())
          .firstWhere((d) => d.field.contains('release-dev'));
      expect(casing.reason, contains('case-sensitively'));
      expect(casing.remedy, contains('Release-dev'));
    });

    test('`Release-Dev` is valid on its own — it declares a flavor named `Dev`',
        () async {
      // The casing problem people actually hit is that Android declares `dev`
      // while Xcode declares `Dev`. That is a cross-platform mismatch, not a
      // malformed configuration, so the iOS reader alone must not flag it.
      project
        ..withPubspec()
        ..withIosProject()
        ..withSharedScheme('Dev',
            launch: 'Debug-Dev', archive: 'Release-Dev');
      stubBridge(
        runner,
        stubBridgeJson(
          configurations: <String, String>{
            'Debug': 'com.acme.app',
            'Release': 'com.acme.app',
            'Profile': 'com.acme.app',
            'Debug-Dev': 'com.acme.app.dev',
            'Release-Dev': 'com.acme.app.dev',
            'Profile-Dev': 'com.acme.app.dev',
          },
        ),
      );

      expect(defectsOf(await inspect()), isEmpty);
    });

    test('a scheme living only in xcuserdata is called out', () async {
      project
        ..withPubspec()
        ..withIosProject()
        ..withUserScheme('dev',
            owner: 'alice', launch: 'Debug-dev', archive: 'Release-dev');
      stubBridge(
        runner,
        stubBridgeJson(
          configurations: <String, String>{
            'Debug': 'com.acme.app',
            'Release': 'com.acme.app',
            'Profile': 'com.acme.app',
            'Debug-dev': 'com.acme.app.dev',
            'Release-dev': 'com.acme.app.dev',
            'Profile-dev': 'com.acme.app.dev',
          },
        ),
      );

      final result = await inspect();
      expect(result.ios.schemes['dev']!.shared, isFalse);
      expect(result.ios.schemes['dev']!.owner, 'alice');

      final defect = defectsOf(result)
          .firstWhere((d) => d.field == 'ios.schemes.dev');
      expect(defect.reason, contains('xcuserdata'));
      expect(defect.reason, contains('alice'));
      expect(defect.remedy, contains('Shared'));
    });

    test('a shared scheme wins over a user scheme of the same name', () async {
      project
        ..withPubspec()
        ..withIosProject()
        ..withUserScheme('dev', owner: 'alice', launch: 'Debug')
        ..withSharedScheme('dev',
            launch: 'Debug-dev', archive: 'Release-dev');
      stubBridge(
        runner,
        stubBridgeJson(
          configurations: <String, String>{
            'Debug': 'com.acme.app',
            'Release': 'com.acme.app',
            'Profile': 'com.acme.app',
            'Debug-dev': 'com.acme.app.dev',
            'Release-dev': 'com.acme.app.dev',
            'Profile-dev': 'com.acme.app.dev',
          },
        ),
      );

      final result = await inspect();
      expect(result.ios.schemes['dev']!.shared, isTrue);
      expect(result.ios.schemes['dev']!.buildConfiguration, 'Debug-dev');
    });

    test('a flavor missing one build type is reported with the missing name',
        () async {
      project
        ..withPubspec()
        ..withIosProject()
        ..withSharedScheme('dev',
            launch: 'Debug-dev', archive: 'Release-dev');
      stubBridge(
        runner,
        stubBridgeJson(
          configurations: <String, String>{
            'Debug': 'com.acme.app',
            'Release': 'com.acme.app',
            'Profile': 'com.acme.app',
            'Debug-dev': 'com.acme.app.dev',
            'Release-dev': 'com.acme.app.dev',
            // Profile-dev is absent: the flavor works until someone runs a
            // profile build.
          },
        ),
      );

      final defect = defectsOf(await inspect())
          .firstWhere((d) => d.field == 'ios.flavors.dev');
      expect(defect.reason, contains('Profile-dev'));
    });

    test('a scheme pointing at a configuration that does not exist', () async {
      project
        ..withPubspec()
        ..withIosProject()
        ..withSharedScheme('dev',
            launch: 'Debug-dev', archive: 'Release-ghost');
      stubBridge(
        runner,
        stubBridgeJson(
          configurations: <String, String>{
            'Debug': 'com.acme.app',
            'Release': 'com.acme.app',
            'Profile': 'com.acme.app',
            'Debug-dev': 'com.acme.app.dev',
            'Release-dev': 'com.acme.app.dev',
            'Profile-dev': 'com.acme.app.dev',
          },
        ),
      );

      final defect = defectsOf(await inspect()).firstWhere(
        (d) => d.reason.contains('Release-ghost'),
      );
      expect(defect.remedy, contains('existing configuration'));
    });

    test('a flavor with configurations but no scheme cannot be selected',
        () async {
      project
        ..withPubspec()
        ..withIosProject();
      stubBridge(
        runner,
        stubBridgeJson(
          configurations: <String, String>{
            'Debug': 'com.acme.app',
            'Release': 'com.acme.app',
            'Profile': 'com.acme.app',
            'Debug-dev': 'com.acme.app.dev',
            'Release-dev': 'com.acme.app.dev',
            'Profile-dev': 'com.acme.app.dev',
          },
        ),
      );

      final defect = defectsOf(await inspect())
          .firstWhere((d) => d.field == 'ios.schemes');
      expect(defect.reason, contains('no scheme'));
      expect(defect.remedy, contains('shared scheme named `dev`'));
    });
  });

  group('xcconfig resolution', () {
    test('resolves a bundle id that lives in an xcconfig', () async {
      project
        ..withPubspec()
        ..withIosProject()
        ..withXcconfig('dev', 'FLAVOR_BUNDLE_SUFFIX = .dev\n')
        ..withSharedScheme('dev',
            launch: 'Debug-dev', archive: 'Release-dev');
      stubBridge(
        runner,
        stubBridgeJson(
          configurations: <String, String>{
            'Debug': 'com.acme.app',
            'Release': 'com.acme.app',
            'Profile': 'com.acme.app',
            'Debug-dev': r'com.acme.app$(FLAVOR_BUNDLE_SUFFIX)',
            'Release-dev': r'com.acme.app$(FLAVOR_BUNDLE_SUFFIX)',
            'Profile-dev': r'com.acme.app$(FLAVOR_BUNDLE_SUFFIX)',
          },
          baseConfigurationReferences: <String, String>{
            'Debug-dev': 'ios/Flutter/dev.xcconfig',
            'Release-dev': 'ios/Flutter/dev.xcconfig',
            'Profile-dev': 'ios/Flutter/dev.xcconfig',
          },
        ),
      );

      final result = await inspect();
      expect(
        result.ios.applicationTarget!
            .buildConfigurations['Release-dev']!
            .bundleIdentifier,
        'com.acme.app.dev',
      );
    });

    test('an unresolvable reference becomes an uncertainty, not a bad value',
        () async {
      project
        ..withPubspec()
        ..withIosProject()
        ..withSharedScheme('dev',
            launch: 'Debug-dev', archive: 'Release-dev');
      stubBridge(
        runner,
        stubBridgeJson(
          configurations: <String, String>{
            'Debug': 'com.acme.app',
            'Release': 'com.acme.app',
            'Profile': 'com.acme.app',
            'Debug-dev': r'com.acme.app$(MISSING_VAR)',
            'Release-dev': r'com.acme.app$(MISSING_VAR)',
            'Profile-dev': r'com.acme.app$(MISSING_VAR)',
          },
        ),
      );

      final result = await inspect();
      expect(
        result.ios.applicationTarget!
            .buildConfigurations['Release-dev']!
            .bundleIdentifier,
        isNull,
        reason: 'must not report a half-substituted string as fact',
      );
      expect(
        result.uncertainties.any(
          (u) => u.reason.contains(r'$(MISSING_VAR)'),
        ),
        isTrue,
      );
    });
  });

  group('bridge failures degrade gracefully', () {
    test('a bridge error becomes a defect rather than a crash', () async {
      project
        ..withPubspec()
        ..withIosProject();
      runner.stub(
        'xcodeproj_bridge.rb read',
        exitCode: 1,
        stdout: '{"ok":false,"error":{"code":"gem_too_old",'
            '"message":"xcodeproj 1.22.0 is installed.",'
            '"remedy":"Run `gem update xcodeproj`."}}',
      );

      final result = await inspect();
      expect(result.ios.exists, isFalse);
      final defect = defectsOf(result).single;
      expect(defect.reason, contains('1.22.0'));
      expect(defect.remedy, contains('gem update xcodeproj'));
    });

    test('a project with no ios/ directory is a note, not a failure', () async {
      project.withPubspec();
      final result = await inspect();
      expect(result.ios.exists, isFalse);
      expect(defectsOf(result), isEmpty);
      expect(
        result.uncertainties.single.severity,
        UncertaintySeverity.informational,
      );
    });
  });

  group('shell script phases', () {
    test('a Firebase plist copy step is recognised', () async {
      project
        ..withPubspec()
        ..withIosProject();
      stubBridge(
        runner,
        stubBridgeJson(
          configurations: <String, String>{'Release': 'com.acme.app'},
          shellScriptPhases: <Map<String, Object?>>[
            <String, Object?>{
              'isa': 'PBXShellScriptBuildPhase',
              'name': 'Copy Firebase config',
              'shellScript':
                  'cp "config/\$CONFIGURATION/GoogleService-Info.plist" ...',
              'inputPaths': <String>[],
              'outputPaths': <String>[],
            },
          ],
        ),
      );

      final phases = (await inspect()).ios.applicationTarget!.shellScriptPhases;
      expect(phases.single.looksLikeFirebaseCopy, isTrue);
    });
  });
}
