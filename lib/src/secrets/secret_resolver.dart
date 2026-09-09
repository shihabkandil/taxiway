import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/env/run_environment.dart';
import '../core/io/process_runner.dart';
import '../core/io/redactor.dart';
import 'secret_requirements.dart';

/// Where a value was found.
enum SecretSource {
  environment,
  dotenv,
  keychain,

  /// Present, but the path it names does not exist — the same failure as being
  /// unset, only discovered later.
  missingFile,

  /// Not found anywhere the environment allows looking.
  absent,

  /// Would be asked for interactively. Only reachable on a workstation.
  prompt;

  bool get found =>
      this == SecretSource.environment ||
      this == SecretSource.dotenv ||
      this == SecretSource.keychain;
}

/// What became of one secret. Deliberately carries no value.
///
/// The type is the guarantee: `taxiway secrets list` cannot print a credential
/// because it is never handed one. Anything wanting the value asks
/// [SecretResolver.read] and gets it registered with the redactor first.
class SecretStatus {
  const SecretStatus({
    required this.requirement,
    required this.source,
    this.detail,
  });

  final SecretRequirement requirement;
  final SecretSource source;

  /// Where it came from, in words — a file path, a keychain name.
  final String? detail;

  String get name => requirement.name;

  /// Whether this blocks a run: required, and not found.
  bool get blocks => requirement.isRequired && !source.found;
}

/// Resolves secrets by name, in the order the environment permits.
///
/// The chain is a property of the environment rather than a constant. On a
/// workstation it ends in a prompt; anywhere else it ends in a failure that
/// names what is missing, because a prompt on a runner is a hang, and a hang
/// burns the job timeout while reporting nothing.
class SecretResolver {
  SecretResolver({
    required this.environment,
    required this.projectRoot,
    required this.runner,
    required this.redactor,
    Map<String, String>? processEnvironment,
    this.keychainService = defaultKeychainService,
    this.flavor,
  }) : _processEnvironment = processEnvironment ?? Platform.environment;

  /// The generic-password service taxiway stores secrets under.
  static const String defaultKeychainService = 'taxiway';

  final RunEnvironment environment;
  final String projectRoot;
  final ProcessRunner runner;

  /// Every value read is registered here before it is returned, so a secret
  /// echoed by a subprocess never reaches a terminal or a log.
  final Redactor redactor;

  final String keychainService;

  /// Selects `.env.<flavor>`, when the config names a per-flavor file.
  final String? flavor;

  final Map<String, String> _processEnvironment;

  Map<String, String>? _dotenv;

  /// Where each source may be consulted, in order, for this environment.
  ///
  /// The login keychain is absent off the workstation on purpose: on a headless
  /// Mac it may not be unlocked after a reboot, and depending on it is what
  /// makes self-hosted builders fail in ways that look like signing problems.
  List<SecretSource> get chain => switch (environment) {
    RunEnvironment.workstation => const <SecretSource>[
      SecretSource.environment,
      SecretSource.dotenv,
      SecretSource.keychain,
      SecretSource.prompt,
    ],
    RunEnvironment.ephemeralCi => const <SecretSource>[
      SecretSource.environment,
    ],
    RunEnvironment.persistentRunner => const <SecretSource>[
      SecretSource.environment,
      SecretSource.dotenv,
    ],
  };

  /// Reports on [requirement] without exposing its value.
  Future<SecretStatus> status(SecretRequirement requirement) async {
    for (final source in chain) {
      final found = await _read(requirement.name, source);
      if (found == null) continue;

      if (requirement.isPath && !_fileExists(found)) {
        return SecretStatus(
          requirement: requirement,
          source: SecretSource.missingFile,
          detail: found,
        );
      }
      return SecretStatus(
        requirement: requirement,
        source: source,
        detail: _describe(source),
      );
    }

    return SecretStatus(
      requirement: requirement,
      source: SecretSource.absent,
      detail: environment.mayPrompt
          ? null
          : 'not set, and this environment cannot prompt',
    );
  }

  Future<List<SecretStatus>> statuses(
    Iterable<SecretRequirement> requirements,
  ) async => <SecretStatus>[
    for (final requirement in requirements) await status(requirement),
  ];

  /// The actual value, registered with the redactor before it is returned.
  Future<String?> read(String name) async {
    for (final source in chain) {
      final value = await _read(name, source);
      if (value == null) continue;
      redactor.register(value);
      return value;
    }
    return null;
  }

  Future<String?> _read(String name, SecretSource source) async =>
      switch (source) {
        SecretSource.environment => _nonEmpty(_processEnvironment[name]),
        SecretSource.dotenv => _nonEmpty((await _loadDotenv())[name]),
        SecretSource.keychain => await _readKeychain(name),
        // A prompt is not a lookup; it is what the caller does when the chain
        // runs out, and only where the environment allows it.
        _ => null,
      };

  String? _describe(SecretSource source) => switch (source) {
    SecretSource.environment => 'environment',
    SecretSource.dotenv => dotenvPath,
    SecretSource.keychain => 'keychain ($keychainService)',
    _ => null,
  };

  /// `.env.<flavor>` when a flavor is in play, otherwise `.env`.
  String get dotenvPath => flavor == null ? '.env' : '.env.$flavor';

  Future<Map<String, String>> _loadDotenv() async {
    final cached = _dotenv;
    if (cached != null) return cached;

    final file = File(p.join(projectRoot, dotenvPath));
    if (!file.existsSync()) return _dotenv = const <String, String>{};
    return _dotenv = parseDotenv(await file.readAsString());
  }

  Future<String?> _readKeychain(String name) async {
    if (!environment.mayUseLoginKeychain || !Platform.isMacOS) return null;

    final result = await runner.run('security', <String>[
      'find-generic-password',
      '-s',
      keychainService,
      '-a',
      name,
      '-w',
    ]);
    // A missing item is an ordinary answer, not a failure worth reporting.
    if (!result.ok) return null;
    return _nonEmpty(result.stdout.trim());
  }

  bool _fileExists(String path) =>
      File(p.isAbsolute(path) ? path : p.join(projectRoot, path)).existsSync();

  static String? _nonEmpty(String? value) =>
      (value == null || value.trim().isEmpty) ? null : value;

  /// A deliberately small `.env` parser.
  ///
  /// Handles what these files actually contain — `KEY=value`, comments, blank
  /// lines, optional `export`, and quoted values — and nothing more. A full
  /// shell parser would invite people to put logic in a secrets file.
  static Map<String, String> parseDotenv(String contents) {
    final values = <String, String>{};
    for (final raw in contents.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      final withoutExport = line.startsWith('export ')
          ? line.substring('export '.length).trim()
          : line;
      final separator = withoutExport.indexOf('=');
      if (separator <= 0) continue;

      final key = withoutExport.substring(0, separator).trim();
      var value = withoutExport.substring(separator + 1).trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      values[key] = value;
    }
    return values;
  }
}
