import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/io/process_runner.dart';
import '../../core/model/project_model.dart';

/// The outcome of configuring an Xcode project.
class MutationResult {
  const MutationResult({
    required this.changed,
    required this.changes,
    this.backupPath,
    this.failureReason,
    this.failureRemedy,
    this.restored = false,
  });

  /// True when the project file was actually modified.
  final bool changed;

  /// Human-readable list of what changed, from the bridge.
  final List<String> changes;

  /// Where the pre-mutation copy was written.
  final String? backupPath;

  final String? failureReason;
  final String? failureRemedy;

  /// True when a failure was followed by a successful restore.
  final bool restored;

  bool get succeeded => failureReason == null;
}

/// One build configuration taxiway wants to exist.
class DesiredConfiguration {
  const DesiredConfiguration({
    required this.name,
    required this.basedOn,
    this.xcconfig,
    this.inheritBaseConfiguration = false,
    this.buildSettings = const <String, String>{},
  });

  /// e.g. `Release-dev`.
  final String name;

  /// The build type it derives from, e.g. `Release`.
  final String basedOn;

  /// Path to the flavor's xcconfig, relative to `ios/`.
  final String? xcconfig;

  /// Take the base configuration from [basedOn] rather than naming a file.
  ///
  /// The only correct choice for a flavor configuration. `Release-dev` must
  /// read whatever `Release` reads — normally `ios/Flutter/Release.xcconfig`,
  /// which is what includes `Generated.xcconfig` and, in a CocoaPods project,
  /// the generated `Pods-Runner` config. Pointing it at a taxiway-written
  /// xcconfig instead displaces all of that: the build loses FLUTTER_TARGET
  /// and compiles `lib/main.dart` whatever `-t` said, loses every
  /// `--dart-define`, and produces an Info.plist with no CFBundleVersion.
  ///
  /// Read from the project rather than assumed, because a project is free to
  /// point `Profile` somewhere other than `Release.xcconfig`.
  final bool inheritBaseConfiguration;

  /// Settings written onto the configuration itself.
  ///
  /// A target's own build settings take precedence over its base configuration,
  /// so anything that must actually take effect — the flavor's bundle id above
  /// all — belongs here rather than only in the xcconfig.
  final Map<String, String> buildSettings;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'basedOn': basedOn,
    if (inheritBaseConfiguration) 'inheritBaseConfiguration': true,
    if (xcconfig != null) 'xcconfig': xcconfig,
    if (buildSettings.isNotEmpty) 'buildSettings': buildSettings,
  };
}

/// Mutates `ios/Runner.xcodeproj/project.pbxproj` through the Ruby bridge.
///
/// The riskiest thing taxiway does. Every mutation is preceded by a byte-exact
/// backup and followed by a re-read that checks the project says what it was
/// asked to say; anything short of complete success restores the original file.
///
/// This is an adapter, not a [Generator]: it is a process call rather than a
/// file render, so it runs after the generators have written the xcconfigs it
/// points at.
class XcodeProjectMutator {
  const XcodeProjectMutator({
    required this.runner,
    required this.scriptPath,
    required this.root,
  });

  final ProcessRunner runner;

  /// Path to `tool/ruby/xcodeproj_bridge.rb`.
  final String scriptPath;

  /// Project root.
  final String root;

  static const String projectDirectory = 'ios/Runner.xcodeproj';
  static const String pbxprojPath = '$projectDirectory/project.pbxproj';
  static const String backupDirectory = '.taxiway/backups';

  /// Name of the run-script phase taxiway owns.
  ///
  /// Prefixed so it is obviously ours in Xcode's UI, and matched by name on
  /// every run so re-configuring updates it instead of appending another.
  static const String firebasePhaseName = 'taxiway: Copy Firebase config';

  /// Builds the run script that copies the right `GoogleService-Info.plist`.
  ///
  /// Keyed off `$CONFIGURATION` rather than a build setting so it works even
  /// when a configuration has no xcconfig attached, and fails the build loudly
  /// rather than shipping an app pointed at the wrong Firebase project.
  static String? firebaseScript(Map<String, String> plistByConfiguration) {
    if (plistByConfiguration.isEmpty) return null;

    final buffer = StringBuffer()
      ..writeln('# Managed by taxiway. Edit taxiway.yaml and re-run')
      ..writeln('# `taxiway generate` instead of changing this script.')
      ..writeln('set -e')
      ..writeln()
      ..writeln('case "\$CONFIGURATION" in');
    for (final entry in plistByConfiguration.entries) {
      buffer
        ..writeln('  "${entry.key}")')
        ..writeln('    PLIST="\${SRCROOT}/../${entry.value}" ;;');
    }
    buffer
      ..writeln('  *)')
      ..writeln('    echo "taxiway: no Firebase config for \$CONFIGURATION" ;;')
      ..writeln('esac')
      ..writeln()
      ..writeln(r'if [ -n "${PLIST:-}" ]; then')
      ..writeln(r'  if [ ! -f "$PLIST" ]; then')
      ..writeln(r'    echo "error: taxiway: $PLIST is missing" >&2; exit 1')
      ..writeln('  fi')
      ..writeln(
        r'  cp "$PLIST" '
        r'"${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/GoogleService-Info.plist"',
      )
      ..writeln('fi');
    return buffer.toString();
  }

  /// Makes the project match [configurations], restoring on any failure.
  Future<MutationResult> configure({
    required List<DesiredConfiguration> configurations,
    Map<String, String> firebasePlists = const <String, String>{},
    String target = 'Runner',
  }) async {
    final pbxproj = File(p.join(root, pbxprojPath));
    if (!pbxproj.existsSync()) {
      return const MutationResult(
        changed: false,
        changes: <String>[],
        failureReason: 'ios/Runner.xcodeproj/project.pbxproj was not found.',
        failureRemedy:
            'Run `flutter create --platforms=ios .` to generate the '
            'iOS project first.',
      );
    }
    if (configurations.isEmpty) {
      return const MutationResult(changed: false, changes: <String>[]);
    }

    final original = await pbxproj.readAsBytes();
    final backup = await _backup(original);

    final script = firebaseScript(firebasePlists);
    final request = jsonEncode(<String, dynamic>{
      'target': target,
      'configurations': configurations.map((c) => c.toJson()).toList(),
      if (script != null)
        'runScript': <String, dynamic>{
          'name': firebasePhaseName,
          'script': script,
        },
    });

    final result = await runner.run(
      'ruby',
      <String>[scriptPath, 'configure', p.join(root, projectDirectory)],
      // The request goes on stdin rather than argv: a project with many flavors
      // produces a payload well past a comfortable argument length.
      stdin: request,
    );

    Future<MutationResult> fail(String reason, {String? remedy}) async {
      final restored = await _restore(pbxproj, original);
      return MutationResult(
        changed: false,
        changes: const <String>[],
        backupPath: backup,
        failureReason: reason,
        failureRemedy: remedy,
        restored: restored,
      );
    }

    if (result.notFound) {
      return fail(
        'Ruby is not installed or not on PATH.',
        remedy: 'Install Ruby 3.0 or later, then `gem install xcodeproj`.',
      );
    }

    final decoded = _decode(result.stdout);
    if (decoded == null) {
      return fail(
        'The Xcode project bridge did not return JSON '
        '(exit ${result.exitCode}).',
        remedy: result.stderr.isEmpty
            ? 'Re-run with --verbose to see its output.'
            : result.stderr.split('\n').take(3).join('\n'),
      );
    }

    if (decoded['ok'] != true) {
      final error = decoded['error'];
      final map = error is Map
          ? error.cast<String, dynamic>()
          : const <String, dynamic>{};
      return fail(
        map['message'] as String? ?? 'The Xcode project bridge failed.',
        remedy: map['remedy'] as String?,
      );
    }

    // Verify by reading back what the bridge itself reports, rather than
    // trusting that "ok" means the project now says what we asked for.
    final missing = _verify(decoded, configurations, target);
    if (missing.isNotEmpty) {
      return fail(
        'The Xcode project still does not declare '
        '${missing.join(', ')} after configuring.',
        remedy:
            'The original project file has been restored. Please report '
            'this with `--verbose` output.',
      );
    }

    return MutationResult(
      changed: decoded['changed'] == true,
      changes: (decoded['changes'] as List<dynamic>? ?? const <dynamic>[])
          .map((c) => c.toString())
          .toList(),
      backupPath: backup,
    );
  }

  /// Configuration names the project should now have but does not.
  List<String> _verify(
    Map<String, dynamic> response,
    List<DesiredConfiguration> wanted,
    String targetName,
  ) {
    final project = response['project'];
    if (project is! Map<String, dynamic>) {
      return wanted.map((c) => c.name).toList();
    }
    final targets = (project['targets'] as List<dynamic>? ?? const <dynamic>[])
        .cast<Map<String, dynamic>>();
    final target = targets.cast<Map<String, dynamic>?>().firstWhere(
      (t) => t?['name'] == targetName,
      orElse: () => null,
    );
    if (target == null) return wanted.map((c) => c.name).toList();

    final present =
        (target['buildConfigurations'] as List<dynamic>? ?? const <dynamic>[])
            .cast<Map<String, dynamic>>()
            .map((c) => c['name'] as String?)
            .whereType<String>()
            .toSet();

    return wanted
        .map((c) => c.name)
        .where((name) => !present.contains(name))
        .toList();
  }

  /// Copies the project file to `.taxiway/backups/<timestamp>/`.
  Future<String> _backup(List<int> original) async {
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final directory = Directory(p.join(root, backupDirectory, stamp));
    await directory.create(recursive: true);
    final destination = File(p.join(directory.path, 'project.pbxproj'));
    await destination.writeAsBytes(original, flush: true);
    return p.join(backupDirectory, stamp, 'project.pbxproj');
  }

  /// Puts the original bytes back. Returns false if even that failed.
  Future<bool> _restore(File pbxproj, List<int> original) async {
    try {
      await pbxproj.writeAsBytes(original, flush: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static Map<String, dynamic>? _decode(String stdout) {
    final trimmed = stdout.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// The configurations a set of flavors requires, paired with their xcconfigs.
  static List<DesiredConfiguration> configurationsFor(
    Iterable<String> flavors, {
    String? Function(String flavor)? bundleIdFor,
    String? Function(String flavor)? displayNameFor,
    String? teamId,
  }) => <DesiredConfiguration>[
    for (final flavor in flavors)
      for (final buildType in flutterBuildTypes)
        DesiredConfiguration(
          name: '$buildType-$flavor',
          basedOn: buildType,
          // Never a taxiway-written xcconfig: see [inheritBaseConfiguration].
          inheritBaseConfiguration: true,
          // Everything per-flavor lives here, on the configuration itself.
          // That is both what a target's own settings winning over its base
          // configuration requires, and what a hand-made flavor setup does.
          buildSettings: <String, String>{
            // A bundle id left only in an xcconfig builds under the
            // unflavored id.
            if (bundleIdFor?.call(flavor) != null)
              'PRODUCT_BUNDLE_IDENTIFIER': bundleIdFor!(flavor)!,
            // Referenced by Info.plist, which is the only way the home-screen
            // name can vary per build configuration.
            if (displayNameFor?.call(flavor) != null)
              'APP_DISPLAY_NAME': displayNameFor!(flavor)!,
            if (teamId != null) 'DEVELOPMENT_TEAM': teamId,
          },
        ),
  ];
}
