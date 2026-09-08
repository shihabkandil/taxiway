import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../version.dart';
import 'exit_codes.dart';

/// The root command runner.
///
/// Owns global flags and turns thrown failures into stable exit codes, so no
/// individual command has to think about process semantics.
class TaxiwayCommandRunner extends CommandRunner<int> {
  TaxiwayCommandRunner({Logger? logger})
      : _logger = logger ?? Logger(),
        super('taxiway', 'Local-first CI/CD for Flutter apps.') {
    argParser
      ..addFlag(
        'version',
        negatable: false,
        help: 'Print the taxiway version and exit.',
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        negatable: false,
        help: 'Show the commands taxiway runs and their full output.',
      )
      ..addFlag(
        'no-color',
        negatable: false,
        help: 'Disable coloured output.',
      )
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'Assume yes for every prompt. Implies non-interactive.',
      )
      ..addOption(
        'config',
        help: 'Path to taxiway.yaml.',
        valueHelp: 'path',
      )
      ..addOption(
        'app',
        help: 'Which app in a monorepo to act on.',
        valueHelp: 'id',
      );
  }

  final Logger _logger;

  @override
  Future<int> run(Iterable<String> args) async {
    try {
      final topLevel = parse(args);
      if (topLevel['version'] as bool) {
        _logger.info(packageVersion);
        return TaxiwayExit.success;
      }
      if (topLevel['verbose'] as bool) {
        _logger.level = Level.verbose;
      }
      return await runCommand(topLevel) ?? TaxiwayExit.success;
    } on UsageException catch (e) {
      _logger
        ..err(e.message)
        ..info('')
        ..info(e.usage);
      return TaxiwayExit.userError;
    } catch (error, stackTrace) {
      _logger
        ..err('$error')
        ..detail('$stackTrace');
      return TaxiwayExit.internalError;
    }
  }
}
