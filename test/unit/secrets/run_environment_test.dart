import 'package:taxiway/src/core/env/run_environment.dart';
import 'package:test/test.dart';

void main() {
  ResolvedEnvironment resolve({
    String? flag,
    String? configured,
    Map<String, String> environment = const <String, String>{},
  }) => EnvironmentDetector.resolve(
    flag: flag,
    configured: configured,
    environment: environment,
  );

  group('explicit answers win', () {
    test('the flag beats everything', () {
      final resolved = resolve(
        flag: 'workstation',
        configured: 'ci',
        environment: const <String, String>{
          'CI': 'true',
          'TAXIWAY_ENV': 'persistent',
        },
      );
      expect(resolved.environment, RunEnvironment.workstation);
      expect(resolved.source, EnvironmentSource.flag);
    });

    test('the variable beats config and detection', () {
      final resolved = resolve(
        configured: 'ci',
        environment: const <String, String>{
          'CI': 'true',
          'TAXIWAY_ENV': 'workstation',
        },
      );
      expect(resolved.environment, RunEnvironment.workstation);
      expect(resolved.source, EnvironmentSource.variable);
    });

    test('config beats detection', () {
      final resolved = resolve(
        configured: 'persistent',
        environment: const <String, String>{},
      );
      expect(resolved.environment, RunEnvironment.persistentRunner);
      expect(resolved.source, EnvironmentSource.config);
    });

    test('an unrecognised name is ignored rather than guessed at', () {
      final resolved = resolve(flag: 'nonsense');
      expect(resolved.source, EnvironmentSource.detected);
      expect(resolved.environment, RunEnvironment.workstation);
    });
  });

  group('detection', () {
    test('no CI variables means a workstation', () {
      expect(resolve().environment, RunEnvironment.workstation);
    });

    test('a GitHub-hosted runner is ephemeral', () {
      final resolved = resolve(
        environment: const <String, String>{
          'CI': 'true',
          'GITHUB_ACTIONS': 'true',
          'RUNNER_ENVIRONMENT': 'github-hosted',
        },
      );
      expect(resolved.environment, RunEnvironment.ephemeralCi);
    });

    test('a self-hosted runner is persistent', () {
      final resolved = resolve(
        environment: const <String, String>{
          'CI': 'true',
          'GITHUB_ACTIONS': 'true',
          'RUNNER_ENVIRONMENT': 'self-hosted',
        },
      );
      expect(resolved.environment, RunEnvironment.persistentRunner);
    });

    test('CI with no runner hint is assumed persistent', () {
      // The conservative direction: it cleans up after itself and never
      // assumes the machine is about to be thrown away. Getting this backwards
      // would leave keychains on somebody's build box.
      expect(
        resolve(environment: const <String, String>{'CI': 'true'}).environment,
        RunEnvironment.persistentRunner,
      );
    });

    test('an unrecognised RUNNER_ENVIRONMENT falls back, not through', () {
      // The variable is documented but was never verified against a real
      // runner, so an unexpected value must not be trusted.
      expect(
        resolve(
          environment: const <String, String>{
            'CI': 'true',
            'RUNNER_ENVIRONMENT': 'something-new',
          },
        ).environment,
        RunEnvironment.persistentRunner,
      );
    });

    test('CI=false is not CI', () {
      expect(
        resolve(environment: const <String, String>{'CI': 'false'}).environment,
        RunEnvironment.workstation,
      );
    });
  });

  group('what each environment permits', () {
    test('only a workstation may prompt', () {
      // Anywhere else a prompt is a hang, which burns the job timeout and
      // reports nothing.
      expect(RunEnvironment.workstation.mayPrompt, isTrue);
      expect(RunEnvironment.ephemeralCi.mayPrompt, isFalse);
      expect(RunEnvironment.persistentRunner.mayPrompt, isFalse);
    });

    test('only a workstation may touch the login keychain', () {
      // On a headless Mac it may not be unlocked after a reboot.
      expect(RunEnvironment.workstation.mayUseLoginKeychain, isTrue);
      expect(RunEnvironment.persistentRunner.mayUseLoginKeychain, isFalse);
    });

    test('a persistent runner is the shared one', () {
      expect(RunEnvironment.persistentRunner.shared, isTrue);
      expect(RunEnvironment.ephemeralCi.shared, isFalse);
    });

    test('every name round-trips through the flag', () {
      for (final value in RunEnvironment.values) {
        expect(RunEnvironment.parse(value.flagName), value);
      }
    });
  });
}
