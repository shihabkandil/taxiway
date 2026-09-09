import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../../generators/generated_file.dart';
import '../../generators/generated_file_writer.dart';
import '../../generators/generator_registry.dart';
import '../../inspect/xcodeproj_bridge.dart';
import '../../platform/ios/xcode_project_mutator.dart';
import '../exit_codes.dart';
import '../run_context.dart';

/// `taxiway generate` — config to files.
///
/// Refuses to touch anything taxiway does not own. That refusal is the feature:
/// on a real project the Gradle build file and the Xcode project were there
/// first, and generating over them would replace a working build.
class GenerateCommand extends Command<int> {
  GenerateCommand(this._contextProvider) {
    argParser
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Show what would change without writing anything.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help:
            'Overwrite content you have edited inside a taxiway block. '
            'Never overrides an unadopted file.',
      );
  }

  final ContextProvider _contextProvider;

  RunContext get _context => _contextProvider();

  @override
  String get name => 'generate';

  @override
  String get description => 'Write the files taxiway.yaml describes.';

  @override
  String get invocation =>
      'taxiway generate [${GeneratorRegistry.groups.keys.join('|')}]';

  @override
  Future<int> run() async {
    final results = argResults!;
    final context = _context;
    final logger = context.logger;
    final dryRun = results['dry-run'] as bool;
    final force = results['force'] as bool;

    final selector = results.rest.isEmpty ? 'all' : results.rest.first;
    final generators = GeneratorRegistry.select(selector);
    if (generators == null) {
      logger.err(
        'Unknown generator "$selector". '
        'Try one of: ${GeneratorRegistry.names.join(', ')}',
      );
      return TaxiwayExit.userError;
    }

    final config = await context.requireConfig();
    final app = GeneratorRegistry.resolveFor(
      config,
      context.projectRoot,
      appId: context.appId,
    );

    final files = <GeneratedFile>[
      for (final generator in generators) ...generator.render(app),
    ];
    if (files.isEmpty) {
      logger.info(
        'Nothing to generate. This config declares no flavors, so there are '
        'no per-flavor files to write.',
      );
      return TaxiwayExit.success;
    }

    final lock = await context.loadLockFile();
    final writer = GeneratedFileWriter(
      root: context.projectRoot,
      lock: lock,
      force: force,
    );

    final results_ = <WriteResult>[];
    for (final file in files) {
      results_.add(dryRun ? await writer.plan(file) : await writer.write(file));
    }

    if (!dryRun && results_.any((r) => r.outcome.changesFile)) {
      await lock.save(context.projectRoot);
    }

    final exit = _report(results_, dryRun: dryRun);

    // The Xcode project is mutated after the generators, because the build
    // configurations it creates point at xcconfigs the generators just wrote.
    // Skipped when anything was blocked: half-configuring a project is worse
    // than not touching it.
    if (_touchesIos(generators) && app.hasFlavors) {
      final mutation = await _configureXcodeProject(
        app,
        dryRun: dryRun,
        skipped: exit != TaxiwayExit.success,
      );
      if (mutation != null && !mutation.succeeded) {
        return TaxiwayExit.environmentError;
      }
    }

    return exit;
  }

  /// True when the selected generators include anything iOS-shaped.
  bool _touchesIos(List<Generator> generators) =>
      generators.any((g) => g.name == 'ios-schemes' || g.name == 'xcconfigs');

  /// Creates the `<BuildType>-<flavor>` configurations and the Firebase copy
  /// step, backing up and restoring `project.pbxproj` around the change.
  Future<MutationResult?> _configureXcodeProject(
    ResolvedApp app, {
    required bool dryRun,
    required bool skipped,
  }) async {
    final context = _context;
    final logger = context.logger;

    final configurations = XcodeProjectMutator.configurationsFor(
      app.flavors.map((f) => f.name),
      xcconfigFor: (flavor) => 'Flutter/$flavor.xcconfig',
      bundleIdFor: (flavor) => app.flavor(flavor)?.iosBundleId,
    );

    if (dryRun) {
      logger
        ..info('')
        ..info('Xcode project:')
        ..info(
          '  would ensure ${configurations.length} build '
          'configuration${configurations.length == 1 ? '' : 's'}: '
          '${configurations.map((c) => c.name).join(', ')}',
        );
      return null;
    }

    if (skipped) {
      logger
        ..info('')
        ..info(
          'Skipped the Xcode project: something above is blocked, and '
          'half-configuring it is worse than leaving it alone.',
        );
      return null;
    }

    final scriptPath = XcodeprojBridge.locateScript();
    if (scriptPath == null) {
      logger.err(
        'taxiway could not find its own Xcode bridge. This is a packaging '
        'bug, not a problem with your project.',
      );
      return const MutationResult(
        changed: false,
        changes: <String>[],
        failureReason: 'bridge missing',
      );
    }

    final progress = logger.progress('Configuring Xcode project');
    final mutation =
        await XcodeProjectMutator(
          runner: context.runner,
          scriptPath: scriptPath,
          root: context.projectRoot,
        ).configure(
          configurations: configurations,
          firebasePlists: _firebasePlists(app),
        );

    if (!mutation.succeeded) {
      progress.fail('Could not configure the Xcode project');
      logger.err(mutation.failureReason!);
      final remedy = mutation.failureRemedy;
      if (remedy != null) logger.info(remedy);
      logger.info(
        mutation.restored
            ? 'project.pbxproj was restored'
                  '${mutation.backupPath == null ? '' : '; a copy is at '
                            '${mutation.backupPath}'}.'
            : 'project.pbxproj could NOT be restored automatically. '
                  'Recover it from ${mutation.backupPath ?? 'version control'}.',
      );
      return mutation;
    }

    progress.complete(
      mutation.changed
          ? 'Configured Xcode project (${mutation.changes.length} '
                'change${mutation.changes.length == 1 ? '' : 's'})'
          : 'Xcode project already configured',
    );
    return mutation;
  }

  /// Which plist each configuration should copy, keyed by configuration name.
  Map<String, String> _firebasePlists(ResolvedApp app) {
    final plists = <String, String>{};
    for (final flavor in app.flavors) {
      final plist = flavor.firebaseIos;
      if (plist == null) continue;
      for (final configuration in flavor.iosConfigurations) {
        plists[configuration] = plist;
      }
    }
    return plists;
  }

  int _report(List<WriteResult> results, {required bool dryRun}) {
    final logger = _context.logger;
    logger.info('');

    for (final result in results) {
      logger.info('  ${_label(result, dryRun: dryRun)} ${result.path}');
      final description = result.file.description;
      if (description != null && result.outcome != WriteOutcome.unchanged) {
        logger.info('           ${darkGray.wrap(description) ?? description}');
      }
      final reason = result.reason;
      if (reason != null) {
        logger.info('           $reason');
        final remedy = result.remedy;
        if (remedy != null) {
          logger.info('           ${darkGray.wrap(remedy) ?? remedy}');
        }
      }
      if (dryRun && _context.verbose && result.diff.isNotEmpty) {
        for (final line in result.diff.trimRight().split('\n')) {
          logger.info('           ${darkGray.wrap(line) ?? line}');
        }
      }
    }

    final conflicts = results.where((r) => r.outcome.isConflict).toList();
    final failures = results
        .where((r) => r.outcome == WriteOutcome.failed)
        .toList();
    final changed = results.where((r) => r.outcome.changesFile).length;
    final unchanged = results
        .where((r) => r.outcome == WriteOutcome.unchanged)
        .length;

    logger.info('');
    if (dryRun) {
      logger.info(
        '$changed to write, $unchanged already correct'
        '${conflicts.isEmpty ? '' : ', ${conflicts.length} blocked'}.',
      );
      if (!_context.verbose && results.any((r) => r.diff.isNotEmpty)) {
        logger.info(
          darkGray.wrap('Re-run with --verbose to see the diffs.') ?? '',
        );
      }
      logger.info('Nothing was written.');
    } else {
      logger.info(
        '$changed written, $unchanged unchanged'
        '${conflicts.isEmpty ? '' : ', ${conflicts.length} blocked'}.',
      );
    }

    if (conflicts.isNotEmpty) {
      final unadopted = conflicts
          .where((c) => c.outcome == WriteOutcome.conflictUnmanaged)
          .toList();
      logger.info('');
      if (unadopted.isNotEmpty) {
        logger.info(
          '${yellow.wrap('Blocked')} — taxiway does not own '
          '${unadopted.length} of these files.',
        );
        logger.info(
          'Run `taxiway adopt ${unadopted.length == 1 ? unadopted.single.path : 'all'}` '
          'to review the difference and hand them over.',
        );
      }
      // A conflict is a decision the user has to make, so it is a user error
      // rather than a silent partial success.
      return TaxiwayExit.userError;
    }

    if (failures.isNotEmpty) return TaxiwayExit.environmentError;
    return TaxiwayExit.success;
  }

  String _label(WriteResult result, {required bool dryRun}) =>
      switch (result.outcome) {
        WriteOutcome.create =>
          green.wrap(dryRun ? '  create' : ' created') ?? 'create',
        WriteOutcome.update =>
          green.wrap(dryRun ? '  update' : ' updated') ?? 'update',
        WriteOutcome.unchanged => darkGray.wrap('    skip') ?? 'skip',
        WriteOutcome.conflictUnmanaged => yellow.wrap('conflict') ?? 'conflict',
        WriteOutcome.conflictEdited => yellow.wrap('  edited') ?? 'edited',
        WriteOutcome.failed => red.wrap('  failed') ?? 'failed',
      };
}
