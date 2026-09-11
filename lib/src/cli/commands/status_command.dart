import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../../core/managed/lock_file.dart';
import '../../core/model/android_model.dart';
import '../../core/model/model_diff.dart';
import '../../core/model/project_comparison.dart';
import '../../inspect/android_inspector.dart';
import '../../inspect/project_from_config.dart';
import '../../inspect/project_inspector.dart';
import '../exit_codes.dart';
import '../run_context.dart';

/// `shipway status` — semantic drift between `shipway.yaml` and reality.
///
/// Useful long after import: it is how a user finds out that someone added a
/// flavor in Xcode without updating the config, or that a scheme stopped being
/// shared.
class StatusCommand extends Command<int> {
  StatusCommand(this._contextProvider) {
    argParser.addFlag(
      'json',
      negatable: false,
      help: 'Emit the drift report as JSON.',
    );
  }

  final ContextProvider _contextProvider;

  RunContext get _context => _contextProvider();

  @override
  String get name => 'status';

  @override
  String get description => 'Show how this project differs from shipway.yaml.';

  @override
  Future<int> run() async {
    final context = _context;
    final logger = context.logger;
    final config = await context.requireConfig();

    final progress = logger.progress('Reading project');
    final actual = await ProjectInspector(
      runner: context.runner,
    ).readFromDisk(context.projectRoot);
    progress.complete('Read project');

    // The DSL comes from the project, not the config: shipway has no opinion
    // about which dialect a project uses, so comparing them would be noise.
    final dsl =
        actual.android.gradleDsl ??
        AndroidInspector.locateBuildFile(context.projectRoot)?.dsl ??
        GradleDsl.kotlin;

    final expected = ProjectFromConfig.build(
      config,
      root: context.projectRoot,
      appId: context.appId,
      gradleDsl: dsl,
    );

    final diff = compare(expected, actual);
    final lock = await context.loadLockFile();

    if (argResults!['json'] as bool) {
      logger.write(
        '${const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
          'inSync': diff.isEmpty,
          'changes': diff.toJson(),
          'ownership': <String, String>{for (final entry in lock.files.entries) entry.key: entry.value.ownership.name},
        })}\n',
      );
      return ShipwayExit.success;
    }

    _render(diff, lock);
    // Drift is information, not failure: a user runs `status` precisely because
    // they expect the answer might be "yes, things moved".
    return ShipwayExit.success;
  }

  void _render(ModelDiff diff, LockFile lock) {
    final logger = _context.logger;
    logger.info('');

    if (diff.isEmpty) {
      logger.info(
        '${green.wrap('In sync.')} shipway.yaml matches this project.',
      );
    } else {
      logger.info(
        '${yellow.wrap('Drift')} — ${diff.length} '
        'difference${diff.length == 1 ? '' : 's'} between shipway.yaml and '
        'this project:',
      );
      logger.info('');
      for (final change in diff.changes) {
        logger.info('  ${_glyph(change.kind)} ${change.describe()}');
        final note = change.note;
        if (note != null) {
          logger.info('      ${darkGray.wrap(note) ?? note}');
        }
      }
      logger
        ..info('')
        ..info(
          darkGray.wrap(
                'Update shipway.yaml to match the project, or run '
                '`shipway generate` to make the project match the config.',
              ) ??
              '',
        );
    }

    _renderOwnership(lock);
  }

  void _renderOwnership(LockFile lock) {
    final logger = _context.logger;
    if (lock.files.isEmpty) return;

    final counts = <Ownership, int>{};
    for (final entry in lock.files.values) {
      counts[entry.ownership] = (counts[entry.ownership] ?? 0) + 1;
    }

    logger
      ..info('')
      ..info(
        'Files: ${counts.entries.map((e) => '${e.value} ${e.key.name}').join(', ')}',
      );

    if ((counts[Ownership.unmanaged] ?? 0) > 0 &&
        (counts[Ownership.adopted] ?? 0) == 0 &&
        (counts[Ownership.generated] ?? 0) == 0) {
      logger.info(
        darkGray.wrap(
              'shipway does not own any file in this project yet. '
              'Run `shipway adopt` to let it write to one.',
            ) ??
            '',
      );
    }
  }

  static String _glyph(ChangeKind kind) => switch (kind) {
    ChangeKind.onlyInProject => yellow.wrap('+') ?? '+',
    ChangeKind.onlyInConfig => yellow.wrap('-') ?? '-',
    ChangeKind.different => yellow.wrap('~') ?? '~',
  };
}
