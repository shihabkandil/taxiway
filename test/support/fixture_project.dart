import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'recording_process_runner.dart';

/// Builds a Flutter-shaped project in a temp directory.
///
/// Only the files taxiway reads are created. A full `flutter create` is far
/// slower and adds nothing: the readers never look at anything else, and a
/// hand-built fixture can plant the exact defects a test is about.
class FixtureProject {
  FixtureProject._(this.directory);

  final Directory directory;

  String get path => directory.path;

  static Future<FixtureProject> create({String prefix = 'taxiway_fixture'}) async {
    final dir = await Directory.systemTemp.createTemp(prefix);
    return FixtureProject._(dir);
  }

  /// Deletes the fixture. Pass to `addTearDown`.
  Future<void> dispose() async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  }

  File file(String relative) => File(p.join(path, relative));

  String read(String relative) => file(relative).readAsStringSync();

  bool exists(String relative) => file(relative).existsSync();

  void write(String relative, String contents) {
    final target = file(relative);
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(contents);
  }

  void writeJson(String relative, Object value) =>
      write(relative, const JsonEncoder.withIndent('  ').convert(value));

  /// Relative paths of every file, so a test can assert nothing else appeared.
  List<String> allFiles() => directory
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .map((f) => p.relative(f.path, from: path).replaceAll(r'\', '/'))
      .toList()
    ..sort();

  /// The minimum a Flutter project needs for the readers to engage.
  FixtureProject withPubspec({
    String name = 'demo_app',
    String version = '1.0.0+1',
  }) {
    write('pubspec.yaml', 'name: $name\nversion: $version\n');
    return this;
  }

  FixtureProject withGradle(String contents, {bool kotlin = true}) {
    write(
      'android/app/${kotlin ? 'build.gradle.kts' : 'build.gradle'}',
      contents,
    );
    return this;
  }

  FixtureProject withSourceSet(String name) {
    Directory(p.join(path, 'android/app/src', name)).createSync(recursive: true);
    return this;
  }

  FixtureProject withEntrypoint(String suffix) {
    write('lib/main_$suffix.dart', 'void main() {}\n');
    return this;
  }

  FixtureProject withDartDefines(String name, Map<String, String> values) {
    writeJson('dart_defines/$name.json', values);
    return this;
  }

  /// Creates the directory the iOS inspector looks for. Its contents come from
  /// the stubbed bridge, not from disk.
  FixtureProject withIosProject() {
    Directory(p.join(path, 'ios/Runner.xcodeproj')).createSync(recursive: true);
    return this;
  }

  FixtureProject withSharedScheme(
    String name, {
    String? launch,
    String? archive,
  }) {
    write(
      'ios/Runner.xcodeproj/xcshareddata/xcschemes/$name.xcscheme',
      _scheme(launch: launch, archive: archive),
    );
    return this;
  }

  /// A scheme in `xcuserdata` — git-ignored, so it works only for its author.
  FixtureProject withUserScheme(
    String name, {
    required String owner,
    String? launch,
    String? archive,
  }) {
    write(
      'ios/Runner.xcodeproj/xcuserdata/$owner.xcuserdatad/xcschemes/$name.xcscheme',
      _scheme(launch: launch, archive: archive),
    );
    return this;
  }

  FixtureProject withXcconfig(String name, String contents) {
    write('ios/Flutter/$name.xcconfig', contents);
    return this;
  }

  FixtureProject withAndroidGoogleServices(String sourceSet, {String? package}) {
    writeJson('android/app/src/$sourceSet/google-services.json', <String, Object>{
      'project_info': <String, Object>{'project_id': 'demo-project'},
      'client': <Object>[
        <String, Object>{
          'client_info': <String, Object>{
            'mobilesdk_app_id': '1:1234:android:abcd',
            'android_client_info': <String, Object>{
              'package_name': package ?? 'com.example.demo',
            },
          },
        },
      ],
    });
    return this;
  }

  FixtureProject withIosGoogleServices(String directory, {String? bundleId}) {
    write('ios/$directory/GoogleService-Info.plist', '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>BUNDLE_ID</key>
  <string>${bundleId ?? 'com.example.demo'}</string>
  <key>GOOGLE_APP_ID</key>
  <string>1:1234:ios:abcd</string>
  <key>PROJECT_ID</key>
  <string>demo-project</string>
</dict>
</plist>
''');
    return this;
  }

  FixtureProject withFastlane(
    String directory, {
    String? fastfile,
    String? appfile,
    String? matchfile,
  }) {
    if (fastfile != null) write('$directory/Fastfile', fastfile);
    if (appfile != null) write('$directory/Appfile', appfile);
    if (matchfile != null) write('$directory/Matchfile', matchfile);
    return this;
  }

  static String _scheme({String? launch, String? archive}) => '''
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1510" version = "1.7">
  <BuildAction buildImplicitDependencies = "YES" parallelizeBuildables = "YES">
  </BuildAction>
  <TestAction buildConfiguration = "${launch ?? 'Debug'}">
  </TestAction>
  <LaunchAction buildConfiguration = "${launch ?? 'Debug'}">
  </LaunchAction>
  <ProfileAction buildConfiguration = "${archive ?? 'Release'}">
  </ProfileAction>
  <ArchiveAction buildConfiguration = "${archive ?? 'Release'}">
  </ArchiveAction>
</Scheme>
''';
}

/// Builds the JSON the Ruby bridge would return, so the iOS inspector can be
/// tested without Ruby, Xcode, or a hand-written `project.pbxproj`.
///
/// The bridge's own contract is covered separately by an integration test
/// against a real project.
String stubBridgeJson({
  int objectVersion = 60,
  required Map<String, String> configurations,
  String targetName = 'Runner',
  String? developmentTeam = 'ABCDE12345',
  Map<String, String>? baseConfigurationReferences,
  List<Map<String, Object?>> extraTargets = const <Map<String, Object?>>[],
  List<Map<String, Object?>> shellScriptPhases = const <Map<String, Object?>>[],
}) {
  List<Map<String, Object?>> buildConfigurations() => <Map<String, Object?>>[
        for (final entry in configurations.entries)
          <String, Object?>{
            'name': entry.key,
            'buildSettings': <String, Object?>{
              'PRODUCT_BUNDLE_IDENTIFIER': entry.value,
              if (developmentTeam != null) 'DEVELOPMENT_TEAM': developmentTeam,
            },
            'baseConfigurationReference':
                baseConfigurationReferences?[entry.key],
          },
      ];

  return jsonEncode(<String, Object?>{
    'ok': true,
    'bridgeVersion': 1,
    'xcodeprojVersion': '1.28.1',
    'project': <String, Object?>{
      'objectVersion': objectVersion,
      'synchronizedRootGroups': <String>[],
      'rootObject': <String, Object?>{
        'buildConfigurations': <Map<String, Object?>>[
          for (final name in configurations.keys)
            <String, Object?>{'name': name, 'buildSettings': <String, Object?>{}},
        ],
      },
      'targets': <Map<String, Object?>>[
        <String, Object?>{
          'name': targetName,
          'type': 'com.apple.product-type.application',
          'buildConfigurations': buildConfigurations(),
          'buildPhases': shellScriptPhases,
        },
        ...extraTargets,
      ],
    },
  });
}

/// Stubs the bridge invocation on [runner].
void stubBridge(RecordingProcessRunner runner, String json) =>
    runner.stub('xcodeproj_bridge.rb read', stdout: json);
