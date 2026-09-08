import '../../core/io/process_runner.dart';
import '../check.dart';
import '../tool_version.dart';

/// A check that runs one command and compares the version it prints.
///
/// Most of `doctor` is this shape; keeping it in one place means the awkward
/// parts — a tool that reports to stderr, a banner that lies about its own
/// version — are handled once.
class VersionCheck extends Check {
  VersionCheck({
    required this.id,
    required this.title,
    required this.executable,
    required this.arguments,
    required this.minimum,
    this.preferred,
    this.preferLine,
    this.highest = false,
    this.installHint,
    this.docsUrl,
    this.missingIsFatal = true,
    this.belowMinimumIsFatal = true,
    this.reason,
  });

  @override
  final String id;

  @override
  final String title;

  final String executable;
  final List<String> arguments;

  /// Below this, the check fails (or warns, per [belowMinimumIsFatal]).
  final ToolVersion minimum;

  /// Below this but at or above [minimum], the check warns.
  final ToolVersion? preferred;

  final String? preferLine;
  final bool highest;
  final String? installHint;
  final String? docsUrl;

  /// Whether a missing tool blocks shipping.
  final bool missingIsFatal;

  final bool belowMinimumIsFatal;

  /// Why the floor exists, appended to the fix hint.
  final String? reason;

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final result = await context.runner.run(executable, arguments);
    if (result.notFound) {
      return _missing('`$executable` is not installed or not on PATH.');
    }

    final version = ToolVersion.extract(
      result.output,
      preferLine: preferLine,
      highest: highest,
    );

    if (version == null) {
      if (!result.ok) {
        return _missing(
          '`${result.commandLine}` failed: ${_firstLine(result)}',
        );
      }
      return CheckResult.warn(
        'Installed, but taxiway could not read a version from '
        '`${result.commandLine}`.',
        fixHint: 'Run it yourself and check the output looks normal.',
        docsUrl: docsUrl,
      );
    }

    if (version < minimum) {
      final hint = <String>[
        if (installHint != null) installHint!,
        if (reason != null) reason!,
      ].join(' ');
      final detail = '$version found, $minimum or later required.';
      return belowMinimumIsFatal
          ? CheckResult.fail(
              detail,
              version: version,
              fixHint: hint.isEmpty ? null : hint,
              docsUrl: docsUrl,
            )
          : CheckResult.warn(
              detail,
              version: version,
              fixHint: hint.isEmpty ? null : hint,
              docsUrl: docsUrl,
            );
    }

    final preferredFloor = preferred;
    if (preferredFloor != null && version < preferredFloor) {
      return CheckResult.warn(
        '$version found; $preferredFloor or later is recommended.',
        version: version,
        fixHint: reason ?? installHint,
        docsUrl: docsUrl,
      );
    }

    return CheckResult.ok('$version', version: version);
  }

  CheckResult _missing(String detail) => missingIsFatal
      ? CheckResult.fail(detail, fixHint: installHint, docsUrl: docsUrl)
      : CheckResult.warn(detail, fixHint: installHint, docsUrl: docsUrl);

  static String _firstLine(ProcessResultLite result) {
    final output = result.output.trim();
    if (output.isEmpty) return 'exit ${result.exitCode}';
    return output.split('\n').first;
  }
}

/// Flutter, floored by the project's own `flutter_min` when it declares one.
class FlutterCheck extends Check {
  @override
  String get id => 'flutter';

  @override
  String get title => 'Flutter';

  /// Below this, taxiway's generated configuration is not known to work.
  static const ToolVersion absoluteMinimum = ToolVersion(3, 35, 0);

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final declared = context.config?.project.flutterMin;
    final minimum = declared == null
        ? absoluteMinimum
        : (ToolVersion.tryParse(declared) ?? absoluteMinimum);

    return VersionCheck(
      id: id,
      title: title,
      executable: 'flutter',
      arguments: const <String>['--version'],
      minimum: minimum,
      preferLine: 'Flutter',
      installHint: declared == null
          ? 'Upgrade with `flutter upgrade`.'
          : 'Upgrade with `flutter upgrade`, or lower `project.flutter_min` '
                'in taxiway.yaml.',
      docsUrl: 'https://docs.flutter.dev/release/upgrade',
    ).run(context);
  }
}

/// The JDK, which also gates the `--deep` Gradle read.
class JdkCheck extends Check {
  @override
  String get id => 'jdk';

  @override
  String get title => 'JDK';

  /// The versions the Android Gradle Plugin is actually tested against.
  static const List<int> supportedMajors = <int>[17, 21];

  @override
  Future<CheckResult> run(DoctorContext context) async {
    // `java -version` writes to stderr, which is why every check reads
    // ProcessResultLite.output rather than stdout.
    final result = await context.runner.run('java', const <String>['-version']);
    if (result.notFound) {
      return const CheckResult.fail(
        '`java` is not installed or not on PATH.',
        fixHint: 'Install JDK 17 or 21. Android Studio bundles a suitable JDK.',
        docsUrl: 'https://developer.android.com/build/jdks',
      );
    }
    final version = ToolVersion.extract(result.output, preferLine: 'version');
    if (version == null) {
      return const CheckResult.warn(
        'Installed, but taxiway could not read a version from `java -version`.',
      );
    }
    if (supportedMajors.contains(version.major)) {
      return CheckResult.ok('$version', version: version);
    }
    return CheckResult.warn(
      'JDK ${version.major} found; AGP is tested against '
      '${supportedMajors.join(' and ')}.',
      version: version,
      fixHint:
          'Gradle may fail with "Unsupported class file major version". '
          'This also degrades `taxiway import --deep`, which needs a Gradle '
          'build that configures. Point JAVA_HOME at a JDK 17 or 21 install.',
      docsUrl: 'https://developer.android.com/build/jdks',
    );
  }
}

/// The `xcodeproj` gem, which taxiway's Ruby bridge depends on for every read
/// and write of `project.pbxproj`.
class XcodeprojGemCheck extends Check {
  @override
  String get id => 'xcodeproj_gem';

  @override
  String get title => 'xcodeproj gem';

  /// Below this the gem cannot parse `PBXFileSystemSynchronizedRootGroup`,
  /// which Xcode 16 and later write into new projects.
  static const ToolVersion minimum = ToolVersion(1, 26, 0);

  @override
  Future<CheckResult> run(DoctorContext context) async {
    if (!context.hasIos) {
      return const CheckResult.skip('No ios/ directory.');
    }
    final result = await context.runner.run('gem', const <String>[
      'list',
      'xcodeproj',
    ]);
    if (result.notFound) {
      return const CheckResult.fail(
        '`gem` is not available, so taxiway cannot check for xcodeproj.',
        fixHint: 'Install Ruby, then `gem install xcodeproj`.',
      );
    }
    // `gem list` prefixes unrelated version numbers in its warning preamble and
    // lists every installed version on the matching line, so the parse must be
    // pinned to that line and take the highest.
    final version = ToolVersion.extract(
      result.output,
      preferLine: 'xcodeproj',
      highest: true,
    );
    if (version == null) {
      return const CheckResult.fail(
        'The xcodeproj gem is not installed.',
        fixHint: 'Run `gem install xcodeproj`.',
        docsUrl: 'https://rubygems.org/gems/xcodeproj',
      );
    }
    if (version < minimum) {
      return CheckResult.fail(
        '$version found, $minimum or later required.',
        version: version,
        fixHint:
            'Run `gem update xcodeproj`. Older versions fail on Xcode 16+ '
            'projects with "unknown ISA PBXFileSystemSynchronizedRootGroup".',
        docsUrl: 'https://rubygems.org/gems/xcodeproj',
      );
    }
    return CheckResult.ok('$version', version: version);
  }
}
