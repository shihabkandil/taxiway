import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

import '../core/config/config_exception.dart';
import '../core/env/run_environment.dart';
import '../core/config/config_loader.dart';
import '../core/config/taxiway_config.dart';
import '../core/io/process_runner.dart';
import '../core/io/redactor.dart';
import '../core/managed/lock_file.dart';

/// Supplies the current [RunContext].
///
/// Commands are constructed before global flags are parsed, so they must look
/// the context up when they run rather than capture it at construction — or
/// `--config`, `--app`, `--verbose` and `--yes` are silently ignored.
typedef ContextProvider = RunContext Function();

/// Everything a command needs, resolved once by the runner.
///
/// Commands take this rather than reaching for globals, so a test can hand one
/// a [RecordingProcessRunner] and a temp directory and get the real code path.
class RunContext {
  RunContext({
    required this.logger,
    required this.redactor,
    required this.runner,
    required this.projectRoot,
    required this.configPath,
    required this.appId,
    required this.verbose,
    required this.assumeYes,
    this.environmentFlag,
    Map<String, String>? processEnvironment,
    DateTime? now,
  }) : now = now ?? DateTime.now(),
       _processEnvironment = processEnvironment ?? Platform.environment;

  final Logger logger;
  final Redactor redactor;
  final ProcessRunner runner;

  /// Directory taxiway is acting on.
  final String projectRoot;

  /// Explicit `--config` path, if given.
  final String? configPath;

  /// Explicit `--app` id, if given.
  final String? appId;

  final bool verbose;

  /// `--yes`: assume yes and never prompt. Implies non-interactive.
  final bool assumeYes;

  final DateTime now;

  /// `--env`, when given.
  final String? environmentFlag;

  final Map<String, String> _processEnvironment;

  /// Where taxiway is running, resolved once.
  ///
  /// Explicit answers win over detection, because being wrong is expensive
  /// both ways: prompting on a runner hangs the job, and creating throwaway
  /// keychains on a laptop is rude. Read lazily so a command that needs no
  /// config does not pay for loading one.
  ResolvedEnvironment get environment =>
      _environment ??= EnvironmentDetector.resolve(
        flag: environmentFlag,
        configured: _config?.ci.environment,
        environment: _processEnvironment,
      );
  ResolvedEnvironment? _environment;

  TaxiwayConfig? _config;
  bool _configLoaded = false;

  /// Whether a config is present, without throwing if it is not.
  bool get hasConfig => configFile != null;

  File? get configFile {
    final explicit = configPath;
    if (explicit != null) {
      final file = File(explicit);
      return file.existsSync() ? file : null;
    }
    return ConfigLoader.locate(projectRoot);
  }

  /// The config, or null when the project has none.
  ///
  /// `doctor` must work before `init` does, so a missing config is a fact to
  /// report rather than an error to throw.
  Future<TaxiwayConfig?> configOrNull() async {
    if (_configLoaded) return _config;
    _configLoaded = true;
    final file = configFile;
    if (file == null) return null;
    _config = await ConfigLoader.load(file);
    return _config;
  }

  /// The config, throwing a [ConfigException] with a next step when absent.
  Future<TaxiwayConfig> requireConfig() async {
    final config = await configOrNull();
    if (config != null) return config;
    final explicit = configPath;
    throw ConfigException(
      explicit != null
          ? 'No config at $explicit.'
          : 'No taxiway.yaml found in $projectRoot.',
      hint:
          'Run `taxiway import` to derive one from this project, or '
          '`taxiway init` to start from scratch.',
    );
  }

  Future<LockFile> loadLockFile() => LockFile.load(projectRoot);

  String resolve(String relative) => p.join(projectRoot, relative);
}
