import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

import '../../core/config/shipway_config.dart';
import '../../core/errors/classifier.dart';
import '../../generators/generated_file.dart';
import '../../generators/generator_registry.dart';
import '../../secrets/secret_requirements.dart';
import '../../secrets/secret_resolver.dart';
import '../exit_codes.dart';
import '../run_context.dart';

/// Where a build is going.
enum ReleaseTarget {
  testflight('testflight', 'ios', 'beta'),
  appstore('appstore', 'ios', 'release'),
  play('play', 'android', 'play'),
  firebase('firebase', 'android', 'firebase');

  const ReleaseTarget(this.id, this.platform, this.lane);

  final String id;

  /// The platform whose Fastfile holds the lane.
  final String platform;

  /// How the platform is written in a sentence.
  String get platformLabel => platform == 'ios' ? 'an iOS' : 'an Android';

  /// The generated lane this runs.
  final String lane;

  static ReleaseTarget? parse(String? value) {
    for (final target in ReleaseTarget.values) {
      if (target.id == value) return target;
    }
    return null;
  }

  static List<String> get ids => <String>[
    for (final target in ReleaseTarget.values) target.id,
  ];
}

/// `shipway release ios|android --flavor <f> --target <t>`.
///
/// A front door, not a second implementation: it validates, prints the plan,
/// then runs the same generated lane a person could run by hand. Nothing it
/// does is unavailable to somebody who prefers `bundle exec fastlane`.
///
/// The order is the point. Everything cheap and local happens before anything
/// slow or remote, because the failures worth catching — a credential that is
/// not set, a target the config never configured, external distribution with
/// no group — are all knowable in under a second, and finding them after a
/// twenty-minute build is what makes releasing feel dangerous.
class ReleaseCommand extends Command<int> {
  ReleaseCommand(this._contextProvider) {
    argParser
      ..addOption('flavor', abbr: 'f', help: 'Which flavor to ship.')
      ..addOption(
        'target',
        abbr: 't',
        help: 'Where it is going.',
        allowed: ReleaseTarget.ids,
      )
      ..addOption('track', help: 'Play only: override the configured track.')
      ..addOption(
        'rollout',
        help:
            'Play only: user fraction for a staged rollout, e.g. 0.1. supply '
            'derives the release status from it.',
      )
      ..addOption(
        'build-number',
        help:
            'Use this build number instead of the one versioning.strategy '
            'would resolve.',
      )
      ..addOption(
        'version-name',
        help: 'Use this version name instead of the one in pubspec.yaml.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Validate and print the plan, upload nothing.',
      );
  }

  final ContextProvider _contextProvider;

  RunContext get _context => _contextProvider();

  @override
  String get name => 'release';

  @override
  String get description => 'Build a flavor and send it somewhere.';

  @override
  String get invocation =>
      'shipway release ios|android --flavor <flavor> --target <target>';

  @override
  Future<int> run() async {
    final results = argResults!;
    final context = _context;
    final logger = context.logger;

    final platform = results.rest.isEmpty ? null : results.rest.first;
    if (platform != 'ios' && platform != 'android') {
      logger.err(
        platform == null
            ? 'Say which platform to release: `shipway release ios` or '
                  '`shipway release android`.'
            : 'Unknown platform "$platform". Expected ios or android.',
      );
      return ShipwayExit.userError;
    }

    final target = ReleaseTarget.parse(results['target'] as String?);
    if (target == null) {
      final forPlatform = ReleaseTarget.values
          .where((t) => t.platform == platform)
          .map((t) => t.id)
          .join(', ');
      logger.err(
        results['target'] == null
            ? 'Pass --target. For $platform: $forPlatform.'
            : 'Unknown target "${results['target']}". For $platform: '
                  '$forPlatform.',
      );
      return ShipwayExit.userError;
    }
    if (target.platform != platform) {
      logger
        ..err('--target ${target.id} is ${target.platformLabel} destination.')
        ..info(
          'Run `shipway release ${target.platform} --target ${target.id}`.',
        );
      return ShipwayExit.userError;
    }

    if (platform == 'ios' && !Platform.isMacOS) {
      logger.err('An iOS release needs macOS.');
      return ShipwayExit.environmentError;
    }

    final config = await context.requireConfig();
    final app = GeneratorRegistry.resolveFor(
      config,
      context.projectRoot,
      appId: context.appId,
    );

    final flavor = _resolveFlavor(app, results['flavor'] as String?);
    if (flavor == null) return ShipwayExit.userError;

    final problems = _validate(config, app, target, results);
    if (problems.isNotEmpty) {
      for (final problem in problems) {
        logger.err(problem.what);
        logger.info('  ${problem.fix}');
      }
      return ShipwayExit.userError;
    }

    final missing = await _missingSecrets(config, target);
    if (missing.isNotEmpty) {
      logger.err(
        '${missing.length} required '
        '${missing.length == 1 ? 'credential is' : 'credentials are'} not '
        'set: ${missing.join(', ')}',
      );
      logger.info('  shipway secrets list   — where each one is looked for');
      return ShipwayExit.environmentError;
    }

    _printPlan(app, flavor, target, results);

    if (results['dry-run'] as bool) {
      logger
        ..info('')
        ..info('Nothing was uploaded.');
      return ShipwayExit.success;
    }

    return _runLane(target, flavor, results);
  }

  ResolvedFlavor? _resolveFlavor(ResolvedApp app, String? requested) {
    final logger = _context.logger;
    if (!app.hasFlavors) {
      logger
        ..err('This config declares no flavors, so there is nothing to ship.')
        ..info('  Add one to shipway.yaml and run `shipway generate`.');
      return null;
    }
    final names = app.flavors.map((f) => f.name).join(', ');
    if (requested == null) {
      logger.err('Pass --flavor. This config declares: $names.');
      return null;
    }
    final match = app.flavor(requested);
    if (match == null) {
      logger.err('Unknown flavor "$requested". This config declares: $names.');
      return null;
    }
    return match;
  }

  /// Everything knowable without touching the network.
  ///
  /// Each entry names the config key or flag that fixes it, because "invalid
  /// configuration" sends somebody to read a file rather than change a line.
  List<({String what, String fix})> _validate(
    ShipwayConfig config,
    ResolvedApp app,
    ReleaseTarget target,
    ArgResults results,
  ) {
    final problems = <({String what, String fix})>[];

    final configured = switch (target) {
      ReleaseTarget.testflight => app.testflight != null,
      ReleaseTarget.appstore => app.appstore != null,
      ReleaseTarget.play => app.play != null,
      ReleaseTarget.firebase => app.firebase != null,
    };
    if (!configured) {
      problems.add((
        what: 'This config has no ${target.id} target.',
        fix:
            'Add targets.${target.id} to shipway.yaml, then run '
            '`shipway generate fastlane`.',
      ));
    }

    final rollout = results['rollout'] as String?;
    if (rollout != null) {
      if (target != ReleaseTarget.play) {
        problems.add((
          what: '--rollout applies to the play target only.',
          fix: 'Drop it, or release to --target play.',
        ));
      } else {
        final value = double.tryParse(rollout);
        if (value == null || value <= 0 || value > 1) {
          problems.add((
            what: '--rollout must be a fraction above 0 and at most 1.',
            fix: '0.1 means 10% of users. 1 completes the rollout.',
          ));
        }
      }
    }

    if (results['track'] != null && target != ReleaseTarget.play) {
      problems.add((
        what: '--track applies to the play target only.',
        fix: 'Drop it, or release to --target play.',
      ));
    }

    // pilot requires a group alongside external distribution. The config
    // loader refuses this too; a flag could not reintroduce it, but a config
    // written before that check existed can still be on disk.
    final testflight = app.testflight;
    if (target == ReleaseTarget.testflight &&
        testflight != null &&
        testflight.distributeExternal &&
        testflight.groups.isEmpty) {
      problems.add((
        what: 'distribute_external is set with no groups to distribute to.',
        fix: 'Add targets.testflight.groups, or turn distribute_external off.',
      ));
    }

    return problems;
  }

  /// The credentials this target needs that are not resolvable.
  Future<List<String>> _missingSecrets(
    ShipwayConfig config,
    ReleaseTarget target,
  ) async {
    final context = _context;
    final resolver = SecretResolver(
      environment: context.environment.environment,
      projectRoot: context.projectRoot,
      runner: context.runner,
      redactor: context.redactor,
      host: context.host,
    );
    final requirements = SecretRequirements.of(
      config,
      environment: context.environment.environment,
      appId: context.appId,
    );
    // Scoped to this destination: demanding an App Store Connect key before a
    // Play upload is noise, and noise in a pre-flight is how people learn to
    // ignore it.
    final relevant = requirements.where((r) => r.appliesTo(target.id));
    final statuses = await resolver.statuses(relevant);
    return <String>[
      for (final status in statuses)
        if (status.blocks) status.name,
    ];
  }

  /// What is about to happen, printed whether or not it is a dry run.
  ///
  /// Printed on a real run too, so a failure afterwards is legible: the first
  /// question about a broken release is always "which build went where".
  void _printPlan(
    ResolvedApp app,
    ResolvedFlavor flavor,
    ReleaseTarget target,
    ArgResults results,
  ) {
    final logger = _context.logger;
    final identifier = target.platform == 'ios'
        ? flavor.iosBundleId
        : flavor.androidApplicationId;

    logger
      ..info('')
      ..info('  flavor      ${flavor.name}')
      ..info('  identifier  ${identifier ?? darkGray.wrap('not in config')}')
      ..info('  target      ${target.id}');

    if (target == ReleaseTarget.play) {
      final track =
          (results['track'] as String?) ??
          (app.play?.track ?? PlayTrack.internal).name;
      logger.info('  track       $track');

      final rollout =
          results['rollout'] as String? ?? app.play?.rollout?.toString();
      if (rollout != null) {
        // Shown because it is derived rather than configured: supply sets the
        // status from the fraction, and shipway used to demand the pair match.
        final effective = (double.tryParse(rollout) ?? 0) < 1
            ? 'inProgress'
            : 'completed';
        logger.info('  rollout     $rollout → status $effective');
      }
    }

    final version = results['version-name'] as String?;
    final build = results['build-number'] as String?;
    logger.info(
      '  version     ${version ?? 'pubspec'}'
      '+${build ?? 'versioning.strategy: ${app.versioning.strategy.name}'}',
    );
  }

  /// Runs the generated lane, then classifies whatever came back.
  Future<int> _runLane(
    ReleaseTarget target,
    ResolvedFlavor flavor,
    ArgResults results,
  ) async {
    final context = _context;
    final logger = context.logger;

    final directory = p.join(context.projectRoot, target.platform);
    final arguments = <String>[
      'exec',
      'fastlane',
      target.platform,
      target.lane,
      'flavor:${flavor.name}',
      if (results['track'] != null) 'track:${results['track']}',
      if (results['rollout'] != null) 'rollout:${results['rollout']}',
      if (results['build-number'] != null)
        'build_number:${results['build-number']}',
      if (results['version-name'] != null)
        'version_name:${results['version-name']}',
    ];

    logger
      ..info('')
      ..detail('Running: bundle ${arguments.join(' ')}');

    final result = await context.runner.run(
      'bundle',
      arguments,
      workingDirectory: directory,
    );

    if (result.ok) {
      logger.info(green.wrap('Released ${flavor.name} to ${target.id}.') ?? '');
      // A store upload can succeed and still be rejected in processing, so the
      // output of a success is worth reading too.
      _reportDiagnoses(result.output, asWarning: true);
      return ShipwayExit.success;
    }

    if (result.notFound) {
      logger
        ..err('bundler is not available.')
        ..info(
          '  Install it, then run `bundle install` in ${target.platform}/.',
        );
      return ShipwayExit.environmentError;
    }

    logger.info(result.output);
    _reportDiagnoses(result.output);
    return ShipwayExit.environmentError;
  }

  void _reportDiagnoses(String output, {bool asWarning = false}) {
    final logger = _context.logger;
    for (final diagnosis in ErrorClassifier.classifyAll(output)) {
      logger.info('');
      if (asWarning) {
        logger.warn(diagnosis.summary);
      } else {
        logger.err(diagnosis.summary);
      }
      logger.info('  ${diagnosis.fix}');
    }
  }
}
