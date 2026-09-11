import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

import '../../core/config/config_loader.dart';
import '../../inspect/config_from_project.dart';
import '../../inspect/config_writer.dart';
import '../../inspect/project_inspector.dart';
import '../../version.dart';
import '../exit_codes.dart';
import '../run_context.dart';

/// `shipway init` — a thin front door.
///
/// Almost every project that needs shipway already has flavors, schemes and
/// often fastlane. Asking such a user to answer greenfield prompts would
/// produce a config that contradicts their working build, so `init` looks first
/// and hands off to `import` whenever there is anything to read.
class InitCommand extends Command<int> {
  InitCommand(this._contextProvider) {
    argParser.addFlag(
      'force',
      negatable: false,
      help: 'Overwrite an existing shipway.yaml.',
    );
  }

  final ContextProvider _contextProvider;

  RunContext get _context => _contextProvider();

  @override
  String get name => 'init';

  @override
  String get description => 'Set up shipway in this project.';

  @override
  Future<int> run() async {
    final context = _context;
    final logger = context.logger;
    final force = argResults!['force'] as bool;

    if (!File(p.join(context.projectRoot, 'pubspec.yaml')).existsSync()) {
      logger.err(
        'No pubspec.yaml in ${context.projectRoot}.\n'
        'Run shipway from the root of a Flutter project.',
      );
      return ShipwayExit.userError;
    }

    final existing = ConfigLoader.locate(context.projectRoot);
    if (existing != null && !force) {
      logger
        ..info('${p.basename(existing.path)} already exists.')
        ..info('')
        ..info('  shipway status   see how it differs from this project')
        ..info('  shipway import --force   derive it again from scratch');
      return ShipwayExit.success;
    }

    final progress = logger.progress('Looking at this project');
    final model = await ProjectInspector(
      runner: context.runner,
    ).readFromDisk(context.projectRoot);
    progress.complete('Looked at this project');

    final flavors = model.allFlavors;
    final hasSomethingToRead =
        flavors.isNotEmpty ||
        model.hasFastlane ||
        model.android.applicationId != null ||
        model.ios.applicationTarget != null;

    if (!hasSomethingToRead) {
      logger
        ..info('')
        ..info(
          'This project has no flavors, no fastlane setup, and no readable '
          'application id yet.',
        )
        ..info(
          'There is nothing for shipway to describe, so there is nothing to '
          'write.',
        )
        ..info('')
        ..info(
          'Run `flutter create .` to generate the platform folders, then '
          '`shipway init` again.',
        );
      return ShipwayExit.success;
    }

    // There is a real project here, so describing it beats interrogating the
    // user about it.
    logger.info('');
    if (flavors.isEmpty) {
      logger.info(
        'Found a Flutter project with no flavors. shipway can describe it as a '
        'single-flavor config.',
      );
    } else {
      logger.info(
        'Found ${flavors.length} flavor${flavors.length == 1 ? '' : 's'}: '
        '${(flavors.toList()..sort()).join(', ')}'
        '${model.hasFastlane ? ', plus an existing fastlane setup' : ''}.',
      );
    }

    final proceed =
        context.assumeYes ||
        logger.confirm(
          'Write a shipway.yaml describing it? (nothing else is modified)',
          defaultValue: true,
        );
    if (!proceed) {
      logger
        ..info('')
        ..info(
          'Nothing was written. Run `shipway import --dry-run` to see '
          'what it would produce.',
        );
      return ShipwayExit.success;
    }

    final config = ConfigFromProject.build(model);
    final outPath = p.join(context.projectRoot, ConfigLoader.defaultFileName);
    await File(outPath).writeAsString(
      ConfigWriter.render(
        config,
        generatedBy: packageVersion,
        generatedAt: context.now,
      ),
    );

    logger
      ..info('')
      ..info('${green.wrap('Wrote')} ${ConfigLoader.defaultFileName}')
      ..info('No project files were modified.')
      ..info('')
      ..info('Next:')
      ..info('  shipway status   check it matches your project')
      ..info('  shipway doctor   check this machine can ship it');

    if (model.uncertainties.isNotEmpty) {
      logger.info(
        '  shipway import   see the ${model.uncertainties.length} '
        'finding${model.uncertainties.length == 1 ? '' : 's'} from reading '
        'this project',
      );
    }
    return ShipwayExit.success;
  }
}
