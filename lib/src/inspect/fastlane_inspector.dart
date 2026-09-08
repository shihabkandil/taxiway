import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/model/fastlane_model.dart';
import '../core/model/uncertainty.dart';

class FastlaneInspectResult {
  const FastlaneInspectResult({
    required this.setups,
    required this.uncertainties,
  });

  final List<FastlaneModel> setups;
  final List<Uncertainty> uncertainties;
}

/// Reads an existing fastlane setup statically.
///
/// taxiway never executes a Fastfile. A Fastfile is arbitrary Ruby, so fidelity
/// here is explicitly partial: only literal declarations are read, and the rest
/// is reported as unknown rather than approximated.
class FastlaneInspector {
  const FastlaneInspector();

  /// Where a Flutter project keeps fastlane, per platform.
  static const List<String> searchPaths = <String>[
    'ios/fastlane',
    'android/fastlane',
    'fastlane',
  ];

  Future<FastlaneInspectResult> inspect(String root) async {
    final log = UncertaintyLog();
    final setups = <FastlaneModel>[];

    for (final relative in searchPaths) {
      final dir = Directory(p.join(root, relative));
      if (!dir.existsSync()) continue;
      setups.add(await _readSetup(root, relative, log));
    }

    return FastlaneInspectResult(setups: setups, uncertainties: log.build());
  }

  Future<FastlaneModel> _readSetup(
    String root,
    String relative,
    UncertaintyLog log,
  ) async {
    final directory = p.join(root, relative);
    final platform = relative.startsWith('ios')
        ? 'ios'
        : relative.startsWith('android')
        ? 'android'
        : null;

    final fastfile = await _readIfPresent(p.join(directory, 'Fastfile'));
    final appfile = await _readIfPresent(p.join(directory, 'Appfile'));
    final matchfile = await _readIfPresent(p.join(directory, 'Matchfile'));
    final pluginfile = await _readIfPresent(p.join(directory, 'Pluginfile'));

    final combined = <String>[
      fastfile ?? '',
      appfile ?? '',
      matchfile ?? '',
    ].join('\n');

    if (fastfile != null && _looksDynamic(fastfile)) {
      log.note(
        field: 'fastlane.$relative.lanes',
        reason:
            'this Fastfile builds lanes dynamically or imports another '
            'file, so the lane list taxiway read may be incomplete.',
        remedy:
            'Run `bundle exec fastlane lanes` in $relative to see the '
            'full list.',
        source: '$relative/Fastfile',
      );
    }

    final gemfileDir = p.dirname(directory);
    return FastlaneModel(
      directory: relative,
      // A lane outside any `platform` block belongs to the platform whose
      // directory it lives in, which is how a per-platform setup is written.
      lanes: fastfile == null
          ? const <FastlaneLane>[]
          : _readLanes(fastfile, defaultPlatform: platform),
      appIdentifier: _stringSetting(appfile, 'app_identifier'),
      teamId: _stringSetting(appfile, 'team_id'),
      itcTeamId: _stringSetting(appfile, 'itc_team_id'),
      appleId: _stringSetting(appfile, 'apple_id'),
      matchGitUrl: _stringSetting(matchfile, 'git_url'),
      matchStorageMode: _stringSetting(matchfile, 'storage_mode'),
      matchType: _stringSetting(matchfile, 'type'),
      environmentVariables: readEnvironmentVariables(combined),
      plugins: pluginfile == null ? const <String>[] : _readPlugins(pluginfile),
      hasGemfile: File(p.join(gemfileDir, 'Gemfile')).existsSync(),
      hasGemfileLock: File(p.join(gemfileDir, 'Gemfile.lock')).existsSync(),
    );
  }

  /// Every `ENV['NAME']` / `ENV["NAME"]` / `ENV.fetch('NAME')` referenced.
  ///
  /// Harvested so import can seed the config's `*_ref` fields with the names
  /// the user already chose, instead of asking for them again.
  static Set<String> readEnvironmentVariables(String source) {
    final names = <String>{};
    for (final match in RegExp(
      '''ENV(?:\\.fetch)?\\s*[\\[(]\\s*["']([A-Za-z_][A-Za-z0-9_]*)["']''',
    ).allMatches(source)) {
      names.add(match.group(1)!);
    }
    return names;
  }

  /// Reads `lane :name do` and `private_lane :name do`, tracking the enclosing
  /// `platform :ios do` block.
  static List<FastlaneLane> _readLanes(
    String source, {
    String? defaultPlatform,
  }) {
    final lanes = <FastlaneLane>[];
    String? platform;
    var platformDepth = -1;
    var depth = 0;

    for (final line in source.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('#')) continue;

      final platformMatch = RegExp(
        r'^platform\s+:([a-z_]+)\s+do',
      ).firstMatch(trimmed);
      if (platformMatch != null) {
        platform = platformMatch.group(1);
        platformDepth = depth;
      }

      final laneMatch = RegExp(
        r'^(private_lane|lane)\s+:([A-Za-z_][A-Za-z0-9_]*)',
      ).firstMatch(trimmed);
      if (laneMatch != null) {
        lanes.add(
          FastlaneLane(
            name: laneMatch.group(2)!,
            platform: platform ?? defaultPlatform,
            isPrivate: laneMatch.group(1) == 'private_lane',
          ),
        );
      }

      depth += _blockDelta(trimmed);
      if (platform != null && depth <= platformDepth) {
        platform = null;
        platformDepth = -1;
      }
    }
    return lanes;
  }

  /// Crude Ruby block depth. Enough to scope `platform` blocks; not a parser.
  static int _blockDelta(String line) {
    var delta = 0;
    if (RegExp(r'\bdo\b\s*(\|[^|]*\|)?\s*$').hasMatch(line)) delta++;
    if (RegExp(r'^(if|unless|case|begin|def|class|module)\b').hasMatch(line)) {
      delta++;
    }
    if (RegExp(r'^end\b').hasMatch(line)) delta--;
    return delta;
  }

  static List<String> _readPlugins(String source) => RegExp(
    '''gem\\s+["'](fastlane-plugin-[A-Za-z0-9_-]+)["']''',
  ).allMatches(source).map((m) => m.group(1)!).toList();

  /// Reads `key("value")` or `key "value"` from an Appfile or Matchfile.
  static String? _stringSetting(String? source, String key) {
    if (source == null) return null;
    for (final line in source.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('#')) continue;
      final match = RegExp(
        '''^$key\\s*[( ]\\s*["']([^"']*)["']''',
      ).firstMatch(trimmed);
      if (match != null) return match.group(1);
    }
    return null;
  }

  /// True when the Fastfile does things a static read cannot follow.
  static bool _looksDynamic(String source) =>
      source.contains('import ') ||
      source.contains('import_from_git') ||
      RegExp(r'\.each\s*(do|\{)').hasMatch(source);

  static Future<String?> _readIfPresent(String path) async {
    final file = File(path);
    if (!file.existsSync()) return null;
    return file.readAsString();
  }
}
