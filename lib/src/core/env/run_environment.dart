/// Where taxiway is running, which decides what it is allowed to do.
///
/// One value, resolved once per run, that the secret chain, the keychain
/// strategy and every prompt key off. See `docs/execution-environments.md`.
enum RunEnvironment {
  /// A developer at a machine they are sitting in front of.
  ///
  /// The login keychain is unlocked, a question can be answered, and taxiway
  /// should leave no build-machine debris behind.
  workstation,

  /// A hosted runner that is destroyed after the job.
  ///
  /// Nothing survives the run, so signing material is installed freshly every
  /// time and cleanup is a formality — done anyway, so the code path is the
  /// same one the persistent case exercises.
  ephemeralCi,

  /// A machine that runs builds and keeps running: a self-hosted runner, a
  /// Mac mini in a cupboard.
  ///
  /// The hardest case. It is shared, so anything taxiway changes globally is a
  /// change for every other job; it is headless, so after a reboot the login
  /// keychain is not unlocked; and it is long-lived, so leftovers accumulate.
  persistentRunner;

  /// Whether a question may be asked. Anywhere else a prompt is a hang, which
  /// is worse than a failure: it burns the job timeout and reports nothing.
  bool get mayPrompt => this == RunEnvironment.workstation;

  /// Whether the login keychain may be read or written.
  ///
  /// False off the workstation. On a headless Mac it may not be unlocked at
  /// all, and depending on it is what makes self-hosted builders fail after a
  /// restart in ways that look like signing problems.
  bool get mayUseLoginKeychain => this == RunEnvironment.workstation;

  /// Whether taxiway must remove what it created before exiting.
  bool get requiresCleanup => this != RunEnvironment.workstation;

  /// Whether concurrent runs are plausible and must be guarded against.
  bool get shared => this == RunEnvironment.persistentRunner;

  /// The name accepted by `--env` and `TAXIWAY_ENV`.
  String get flagName => switch (this) {
    RunEnvironment.workstation => 'workstation',
    RunEnvironment.ephemeralCi => 'ci',
    RunEnvironment.persistentRunner => 'persistent',
  };

  static RunEnvironment? parse(String? value) {
    if (value == null) return null;
    return switch (value.trim().toLowerCase()) {
      'workstation' || 'local' || 'laptop' => RunEnvironment.workstation,
      'ci' || 'ephemeral' || 'hosted' => RunEnvironment.ephemeralCi,
      'persistent' ||
      'self-hosted' ||
      'runner' => RunEnvironment.persistentRunner,
      _ => null,
    };
  }

  static List<String> get flagNames => <String>[
    for (final value in RunEnvironment.values) value.flagName,
  ];
}

/// How the environment was decided, so the answer can be explained.
enum EnvironmentSource { flag, variable, config, detected, defaulted }

class ResolvedEnvironment {
  const ResolvedEnvironment({required this.environment, required this.source});

  final RunEnvironment environment;
  final EnvironmentSource source;

  String get explanation => switch (source) {
    EnvironmentSource.flag => 'from --env',
    EnvironmentSource.variable => 'from TAXIWAY_ENV',
    EnvironmentSource.config => 'from ci.environment in taxiway.yaml',
    EnvironmentSource.detected => 'detected',
    EnvironmentSource.defaulted => 'assumed',
  };
}

/// Works out which [RunEnvironment] this is.
///
/// Explicit answers always win. Detection is a convenience, never the only
/// path, because being wrong is expensive in both directions: prompting on a
/// runner hangs the job, and creating throwaway keychains on somebody's laptop
/// is rude.
abstract final class EnvironmentDetector {
  /// Set by essentially every CI system.
  static const String ciVariable = 'CI';

  /// Set by GitHub Actions on both hosted and self-hosted runners.
  static const String githubVariable = 'GITHUB_ACTIONS';

  /// `github-hosted` or `self-hosted`. Documented by GitHub; **not verified
  /// against a real runner here**, so an unrecognised value falls through to
  /// the conservative answer rather than being trusted.
  static const String runnerEnvironmentVariable = 'RUNNER_ENVIRONMENT';

  static const String overrideVariable = 'TAXIWAY_ENV';

  static ResolvedEnvironment resolve({
    String? flag,
    String? configured,
    required Map<String, String> environment,
  }) {
    final fromFlag = RunEnvironment.parse(flag);
    if (fromFlag != null) {
      return ResolvedEnvironment(
        environment: fromFlag,
        source: EnvironmentSource.flag,
      );
    }

    final fromVariable = RunEnvironment.parse(environment[overrideVariable]);
    if (fromVariable != null) {
      return ResolvedEnvironment(
        environment: fromVariable,
        source: EnvironmentSource.variable,
      );
    }

    final fromConfig = RunEnvironment.parse(configured);
    if (fromConfig != null) {
      return ResolvedEnvironment(
        environment: fromConfig,
        source: EnvironmentSource.config,
      );
    }

    return _detect(environment);
  }

  static ResolvedEnvironment _detect(Map<String, String> environment) {
    if (!_isTruthy(environment[ciVariable]) &&
        !_isTruthy(environment[githubVariable])) {
      return const ResolvedEnvironment(
        environment: RunEnvironment.workstation,
        source: EnvironmentSource.detected,
      );
    }

    // On CI. Only a runner GitHub itself owns is safe to treat as disposable.
    final runner = environment[runnerEnvironmentVariable]?.trim().toLowerCase();
    if (runner == 'github-hosted') {
      return const ResolvedEnvironment(
        environment: RunEnvironment.ephemeralCi,
        source: EnvironmentSource.detected,
      );
    }

    // Anything else — self-hosted, or a CI system that sets no such variable —
    // is assumed persistent. That is the conservative direction: it cleans up
    // after itself and never assumes the machine is about to be thrown away.
    return const ResolvedEnvironment(
      environment: RunEnvironment.persistentRunner,
      source: EnvironmentSource.detected,
    );
  }

  static bool _isTruthy(String? value) {
    if (value == null) return false;
    final normalised = value.trim().toLowerCase();
    return normalised == 'true' || normalised == '1';
  }
}
