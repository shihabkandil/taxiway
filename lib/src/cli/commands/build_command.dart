import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../../core/errors/classifier.dart';
import '../../generators/generator_registry.dart';
import '../../generators/generated_file.dart';
import '../exit_codes.dart';
import '../run_context.dart';

/// What `flutter build` is asked to produce.
enum BuildArtifact {
  ipa('ipa', 'ios'),
  appbundle('appbundle', 'android'),
  apk('apk', 'android');

  const BuildArtifact(this.flutterName, this.platform);

  final String flutterName;
  final String platform;
}

/// `taxiway build ios|android --flavor <f>`.
///
/// The command exists because the invocation is easy to get subtly wrong and
/// the consequences are silent. Forgetting `--target` builds `lib/main.dart`
/// under the right bundle id — the wrong app, shipped successfully. Forgetting
/// `--dart-define-from-file` builds against the wrong backend. Neither fails.
///
/// So taxiway constructs the command from the same resolved config the
/// generators used, and a developer never assembles it by hand.
class BuildCommand extends Command<int> {
  BuildCommand(this._contextProvider) {
    argParser
      ..addOption(
        'flavor',
        abbr: 'f',
        help: 'Which flavor to build. Required when the config declares any.',
      )
      ..addOption(
        'artifact',
        help:
            'Android only: what to produce. Defaults to appbundle, which is '
            'what the Play Store takes.',
        allowed: <String>['appbundle', 'apk'],
      )
      ..addFlag(
        'debug',
        negatable: false,
        help: 'Build the debug variant instead of release.',
      )
      ..addFlag(
        'no-codesign',
        negatable: false,
        help:
            'iOS only: archive without signing. What the generated fastlane '
            'lane uses, because gym signs on export.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Print the command that would run, and stop.',
      );
  }

  final ContextProvider _contextProvider;

  RunContext get _context => _contextProvider();

  @override
  String get name => 'build';

  @override
  String get description => 'Build a flavor for one platform.';

  @override
  String get invocation => 'taxiway build ios|android --flavor <flavor>';

  @override
  Future<int> run() async {
    final results = argResults!;
    final context = _context;
    final logger = context.logger;

    final platform = results.rest.isEmpty ? null : results.rest.first;
    if (platform != 'ios' && platform != 'android') {
      logger.err(
        platform == null
            ? 'Say which platform to build: `taxiway build ios` or '
                  '`taxiway build android`.'
            : 'Unknown platform "$platform". Expected ios or android.',
      );
      return TaxiwayExit.userError;
    }

    if (platform == 'ios' && !context.host.canBuildIos) {
      logger.err(
        'An iOS build needs macOS; this is ${context.host.label}. '
        '`taxiway build android` works here.',
      );
      return TaxiwayExit.environmentError;
    }

    final config = await context.requireConfig();
    final app = GeneratorRegistry.resolveFor(
      config,
      context.projectRoot,
      appId: context.appId,
    );

    final flavor = _resolveFlavor(app, results['flavor'] as String?);
    if (flavor is String) {
      logger.err(flavor);
      return TaxiwayExit.userError;
    }
    final resolved = flavor as ResolvedFlavor?;

    final artifact = platform == 'ios'
        ? BuildArtifact.ipa
        : (results['artifact'] == 'apk'
              ? BuildArtifact.apk
              : BuildArtifact.appbundle);

    final arguments = buildArguments(
      artifact: artifact,
      flavor: resolved,
      root: context.projectRoot,
      debug: results['debug'] as bool,
      noCodesign: results['no-codesign'] as bool,
    );

    final commandLine = 'flutter ${arguments.join(' ')}';
    if (results['dry-run'] as bool) {
      logger
        ..info('Would run, from ${context.projectRoot}:')
        ..info('  $commandLine');
      return TaxiwayExit.success;
    }

    logger.detail('Running: $commandLine');
    final progress = logger.progress(
      'Building ${artifact.flutterName}'
      '${resolved == null ? '' : ' (${resolved.name})'}',
    );

    final result = await context.runner.run(
      'flutter',
      arguments,
      workingDirectory: context.projectRoot,
    );

    if (result.ok) {
      progress.complete(
        'Built ${artifact.flutterName}'
        '${resolved == null ? '' : ' (${resolved.name})'}',
      );
      // Flutter exits zero on a build whose Info.plist lost its version keys,
      // so a clean exit code is not on its own proof of a shippable artifact.
      _reportDiagnoses(result.output, asWarning: true);
      _reportArtifact(artifact, resolved);
      return TaxiwayExit.success;
    }

    progress.fail('Build failed');
    if (result.notFound) {
      logger
        ..err('flutter is not on PATH.')
        ..info('Install Flutter, then run `taxiway doctor`.');
      return TaxiwayExit.environmentError;
    }

    // The raw output first — a developer should never have to re-run a build
    // to see what it said — then what taxiway makes of it.
    logger.info(result.output);
    _reportDiagnoses(result.output);
    return TaxiwayExit.environmentError;
  }

  /// Returns the flavor to build, a `String` error message, or null when the
  /// config declares no flavors at all.
  Object? _resolveFlavor(ResolvedApp app, String? requested) {
    if (!app.hasFlavors) {
      return requested == null
          ? null
          : 'This config declares no flavors, so --flavor $requested cannot '
                'be built. Add one to taxiway.yaml and run `taxiway generate`.';
    }
    if (requested == null) {
      return 'Pass --flavor. This config declares: '
          '${app.flavors.map((f) => f.name).join(', ')}.';
    }
    final match = app.flavor(requested);
    if (match == null) {
      return 'Unknown flavor "$requested". This config declares: '
          '${app.flavors.map((f) => f.name).join(', ')}.';
    }
    return match;
  }

  /// The `flutter build` invocation for one flavor.
  ///
  /// Static and pure so a test can assert the exact argument list without
  /// running anything — which is the only way to be sure `--target` is present,
  /// since its absence produces a successful build of the wrong app.
  static List<String> buildArguments({
    required BuildArtifact artifact,
    required ResolvedFlavor? flavor,
    required String root,
    bool debug = false,
    bool noCodesign = false,
  }) {
    final arguments = <String>['build', artifact.flutterName];

    if (debug) {
      arguments.add('--debug');
    } else {
      arguments.add('--release');
    }

    if (flavor != null) {
      arguments
        ..add('--flavor')
        ..add(flavor.name)
        // Never omitted. Without it Flutter builds lib/main.dart under this
        // flavor's bundle id: the wrong app, and the build succeeds.
        ..add('--target')
        ..add(flavor.entrypoint);

      // Only when the file is actually there. Passing a missing one fails the
      // build, and a flavor may legitimately have no defines.
      final defines = definesPathFor(flavor.name);
      if (File(p.join(root, p.joinAll(p.posix.split(defines)))).existsSync()) {
        arguments
          ..add('--dart-define-from-file')
          ..add(defines);
      }
    }

    if (noCodesign && artifact == BuildArtifact.ipa) {
      arguments.add('--no-codesign');
    }

    return arguments;
  }

  /// Where the dart-defines generator writes a flavor's file.
  static String definesPathFor(String flavor) => 'dart_defines/$flavor.json';

  void _reportDiagnoses(String output, {bool asWarning = false}) {
    final logger = _context.logger;
    final diagnoses = ErrorClassifier.classifyAll(output);
    if (diagnoses.isEmpty) return;

    for (final diagnosis in diagnoses) {
      logger.info('');
      if (asWarning) {
        logger.warn(diagnosis.summary);
      } else {
        logger.err(diagnosis.summary);
      }
      logger.info('  ${diagnosis.fix}');
      final url = diagnosis.docsUrl;
      if (url != null) logger.info('  $url');
    }
  }

  void _reportArtifact(BuildArtifact artifact, ResolvedFlavor? flavor) {
    final logger = _context.logger;
    final path = artifactPath(artifact, flavor);
    if (path == null) return;
    final full = File(
      p.join(_context.projectRoot, p.joinAll(p.posix.split(path))),
    );
    if (full.existsSync() || Directory(full.path).existsSync()) {
      logger.info('  $path');
    }
  }

  /// Where Flutter leaves each artifact, so the caller does not have to guess.
  ///
  /// The `.ipa` is deliberately absent: its filename comes from
  /// `CFBundleDisplayName` under a Flutter export and from the product target
  /// under a gym export, so it can only be found by globbing.
  static String? artifactPath(BuildArtifact artifact, ResolvedFlavor? flavor) =>
      switch (artifact) {
        BuildArtifact.ipa => 'build/ios/archive/Runner.xcarchive',
        BuildArtifact.appbundle when flavor != null =>
          'build/app/outputs/bundle/${flavor.name}Release/'
              'app-${flavor.name}-release.aab',
        BuildArtifact.appbundle =>
          'build/app/outputs/bundle/release/'
              'app-release.aab',
        BuildArtifact.apk when flavor != null =>
          'build/app/outputs/flutter-apk/app-${flavor.name}-release.apk',
        BuildArtifact.apk => 'build/app/outputs/flutter-apk/app-release.apk',
      };
}
