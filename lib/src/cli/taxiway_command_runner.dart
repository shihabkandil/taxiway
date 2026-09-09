import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../core/env/host_platform.dart';
import '../core/config/config_exception.dart';
import '../core/io/process_runner.dart';
import '../core/env/run_environment.dart';
import '../core/io/redactor.dart';
import '../core/managed/managed_block.dart';
import '../version.dart';
import 'commands/adopt_command.dart';
import 'commands/build_command.dart';
import 'commands/secrets_command.dart';
import 'commands/doctor_command.dart';
import 'commands/generate_command.dart';
import 'commands/import_command.dart';
import 'commands/init_command.dart';
import 'commands/status_command.dart';
import 'exit_codes.dart';
import 'run_context.dart';

/// The root command runner.
///
/// Owns global flags, builds the one [RunContext] every command shares, and
/// turns thrown failures into stable exit codes so no individual command has to
/// think about process semantics.
class TaxiwayCommandRunner extends CommandRunner<int> {
  TaxiwayCommandRunner({
    Logger? logger,
    ProcessRunner? runner,
    Redactor? redactor,
    String? workingDirectory,
    HostPlatform? host,
  }) : _logger = logger ?? Logger(),
       _redactor = redactor ?? Redactor(),
       _injectedRunner = runner,
       _workingDirectory = workingDirectory ?? Directory.current.path,
       _host = host ?? HostPlatform.current,
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
      ..addFlag('no-color', negatable: false, help: 'Disable coloured output.')
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'Assume yes for every prompt. Implies non-interactive.',
      )
      ..addOption('config', help: 'Path to taxiway.yaml.', valueHelp: 'path')
      ..addOption(
        'app',
        help: 'Which app in a monorepo to act on.',
        valueHelp: 'id',
      )
      ..addOption(
        'env',
        help:
            'Where this is running. Decides which sources secrets may come '
            'from, and whether taxiway may prompt. Detected when omitted.',
        allowed: RunEnvironment.flagNames,
        valueHelp: 'name',
      );

    addCommand(DoctorCommand(() => context));
    addCommand(InitCommand(() => context));
    addCommand(ImportCommand(() => context));
    addCommand(StatusCommand(() => context));
    addCommand(GenerateCommand(() => context));
    addCommand(AdoptCommand(() => context));
    addCommand(BuildCommand(() => context));
    addCommand(SecretsCommand(() => context));
  }

  final Logger _logger;
  final Redactor _redactor;
  final ProcessRunner? _injectedRunner;
  final String _workingDirectory;

  /// Injected so the Linux refusals can be exercised from a Mac.
  final HostPlatform _host;

  /// The context before global flags are parsed. Commands never capture this
  /// directly; they resolve through [context] at run time.
  late final RunContext _initialContext = RunContext(
    logger: _logger,
    redactor: _redactor,
    runner: _injectedRunner ?? SystemProcessRunner(redactor: _redactor),
    projectRoot: _workingDirectory,
    configPath: null,
    appId: null,
    verbose: false,
    assumeYes: false,
    host: _host,
  );

  /// The context commands act on. Replaced once globals are parsed.
  RunContext get context => _resolved ?? _initialContext;
  RunContext? _resolved;

  @override
  Future<int> run(Iterable<String> args) async {
    try {
      final topLevel = parse(args);
      if (topLevel['version'] as bool) {
        _logger.info(packageVersion);
        return TaxiwayExit.success;
      }
      _applyGlobals(topLevel);
      // `overrideAnsiOutput` sets a zone value, which propagates across awaits,
      // so this covers every colour decision the command makes.
      return await overrideAnsiOutput(
        !(topLevel['no-color'] as bool),
        () async => await runCommand(topLevel) ?? TaxiwayExit.success,
      );
    } on UsageException catch (e) {
      _logger
        ..err(e.message)
        ..info('')
        ..info(e.usage);
      return TaxiwayExit.userError;
    } on ConfigException catch (e) {
      // A config problem is the user's to fix and already carries a location
      // and a next step, so print it as-is rather than as a crash.
      _logger.err(e.toString());
      return TaxiwayExit.userError;
    } on ManagedBlockException catch (e) {
      _logger.err(e.message);
      return TaxiwayExit.userError;
    } on ProcessExitException catch (e) {
      _logger.err(e.toString());
      return TaxiwayExit.environmentError;
    } catch (error, stackTrace) {
      _logger
        ..err('$error')
        ..detail('$stackTrace');
      return TaxiwayExit.internalError;
    }
  }

  void _applyGlobals(ArgResults results) {
    final verbose = results['verbose'] as bool;
    if (verbose) _logger.level = Level.verbose;
    _resolved = RunContext(
      logger: _logger,
      redactor: _redactor,
      runner: _initialContext.runner,
      projectRoot: _workingDirectory,
      configPath: results['config'] as String?,
      appId: results['app'] as String?,
      verbose: verbose,
      assumeYes: results['yes'] as bool,
      environmentFlag: results['env'] as String?,
      host: _host,
    );
  }
}
