import 'check.dart';
import 'checks/project_checks.dart';
import 'checks/tool_checks.dart';
import 'platform_deadlines.dart';
import 'tool_version.dart';

/// One check paired with its outcome.
class DoctorEntry {
  const DoctorEntry(this.check, this.result);

  final Check check;
  final CheckResult result;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': check.id,
    'title': check.title,
    'status': result.status.name,
    'detail': result.detail,
    if (result.version != null) 'version': result.version.toString(),
    if (result.fixHint != null) 'fix': result.fixHint,
    if (result.docsUrl != null) 'docs': result.docsUrl,
  };
}

/// The whole run.
class DoctorReport {
  const DoctorReport({required this.entries, required this.generatedAt});

  final List<DoctorEntry> entries;
  final DateTime generatedAt;

  Iterable<DoctorEntry> withStatus(CheckStatus status) =>
      entries.where((e) => e.result.status == status);

  int count(CheckStatus status) => withStatus(status).length;

  /// True when nothing blocks shipping.
  ///
  /// Warnings deliberately do not block: a machine on Ruby 3.1 and JDK 18 can
  /// still produce a signed build, and a doctor that cries failure over that
  /// gets ignored.
  bool get passed => !entries.any((e) => e.result.status.blocks);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'passed': passed,
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'summary': <String, int>{
      for (final status in CheckStatus.values) status.name: count(status),
    },
    'deadlineDataLastVerified': PlatformDeadlines.lastVerified
        .toUtc()
        .toIso8601String(),
    'deadlineDataStale': PlatformDeadlines.isStaleOn(generatedAt),
    'checks': entries.map((e) => e.toJson()).toList(),
  };
}

/// Assembles and runs the check list.
class Doctor {
  Doctor({List<Check>? checks}) : checks = checks ?? defaultChecks();

  final List<Check> checks;

  /// The checks from the plan's table, ordered the way a user reads them:
  /// language toolchain, then Apple, then Ruby, then Android, then project,
  /// then optional extras.
  static List<Check> defaultChecks() => <Check>[
    FlutterCheck(),
    VersionCheck(
      id: 'dart',
      title: 'Dart',
      executable: 'dart',
      arguments: const <String>['--version'],
      // taxiway itself is built against this floor: json_serializable 6.14
      // requires SDK 3.8, so a lower SDK cannot build or run the tool.
      minimum: const ToolVersion(3, 8, 0),
      installHint: 'Dart ships with Flutter; run `flutter upgrade`.',
    ),
    VersionCheck(
      id: 'xcode',
      title: 'Xcode',
      executable: 'xcodebuild',
      arguments: const <String>['-version'],
      minimum: const ToolVersion(26, 0, 0),
      preferLine: 'Xcode',
      installHint:
          'Install Xcode 26 or later, then '
          '`sudo xcode-select -s /Applications/Xcode.app`.',
      reason:
          'App Store Connect has rejected builds made with older Xcode '
          'since 2026-04-28.',
      docsUrl: 'https://developer.apple.com/news/upcoming-requirements/',
    ),
    VersionCheck(
      id: 'cocoapods',
      title: 'CocoaPods',
      executable: 'pod',
      arguments: const <String>['--version'],
      minimum: const ToolVersion(1, 13, 0),
      installHint: 'Run `gem install cocoapods`.',
    ),
    VersionCheck(
      id: 'ruby',
      title: 'Ruby',
      executable: 'ruby',
      arguments: const <String>['--version'],
      minimum: const ToolVersion(3, 0, 0),
      preferred: const ToolVersion(3, 3, 0),
      installHint:
          'Install a newer Ruby with rbenv, asdf or Homebrew; '
          'avoid the system Ruby.',
      reason:
          'fastlane targets Ruby 3.3+; older versions hit gem '
          'compatibility problems that surface as confusing lane failures.',
      docsUrl: 'https://docs.fastlane.tools/getting-started/ios/setup/',
    ),
    VersionCheck(
      id: 'bundler',
      title: 'Bundler',
      executable: 'bundle',
      arguments: const <String>['--version'],
      minimum: const ToolVersion(2, 4, 0),
      installHint: 'Run `gem install bundler`.',
      reason:
          'taxiway always invokes fastlane as `bundle exec fastlane`, '
          'so a pinned Gemfile controls the version.',
    ),
    VersionCheck(
      id: 'fastlane',
      title: 'fastlane',
      executable: 'fastlane',
      arguments: const <String>['--version'],
      minimum: const ToolVersion(2, 220, 0),
      // fastlane's banner prints its own install path, which contains two
      // version numbers that are not its version.
      preferLine: 'fastlane',
      installHint: 'Run `gem install fastlane`, or add it to your Gemfile.',
      docsUrl: 'https://docs.fastlane.tools/',
    ),
    XcodeprojGemCheck(),
    PbxprojObjectVersionCheck(),
    JdkCheck(),
    GradleDslCheck(),
    PlayTargetSdkCheck(),
    FirebaseToolingCheck(executable: 'firebase', name: 'Firebase CLI'),
    FirebaseToolingCheck(executable: 'flutterfire', name: 'flutterfire'),
    KeychainCheck(),
  ];

  /// Runs every check.
  ///
  /// Sequentially on purpose: several shell out to Ruby or Xcode, and running
  /// them in parallel makes a slow machine's output arrive in a jumble while
  /// saving little.
  Future<DoctorReport> run(DoctorContext context) async {
    final entries = <DoctorEntry>[];
    for (final check in checks) {
      entries.add(DoctorEntry(check, await _guard(check, context)));
    }
    return DoctorReport(entries: entries, generatedAt: context.now);
  }

  /// A check that throws is a taxiway bug, not an environment failure, and must
  /// not take the rest of the report down with it.
  Future<CheckResult> _guard(Check check, DoctorContext context) async {
    try {
      return await check.run(context);
    } catch (error) {
      return CheckResult.warn(
        'This check crashed: $error',
        fixHint:
            'That is a taxiway bug. Please report it, with `--verbose` '
            'output.',
      );
    }
  }
}
