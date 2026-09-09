import '../core/config/taxiway_config.dart';
import '../core/env/run_environment.dart';
import '../core/secrets/secret_names.dart';

/// How badly a secret is needed.
enum Need {
  /// A lane cannot run without it.
  required,

  /// Used when set, harmless when not — an override, or an alternative to a
  /// value the config already carries.
  optional,
}

/// One secret the project needs, and what needs it.
class SecretRequirement {
  const SecretRequirement({
    required this.name,
    required this.need,
    required this.wantedBy,
    this.isPath = false,
  });

  /// The environment-variable name.
  final String name;

  final Need need;

  /// What asks for it, phrased so the answer to "why do I need this?" is in
  /// the report rather than in someone's head — a config path where the name
  /// came from a `*_ref`, or the lane that reads it.
  final String wantedBy;

  /// True when the value is a path to a file, so presence means the file
  /// exists rather than merely that the variable is set. A service-account
  /// variable pointing at a file that is not there is the same failure as an
  /// unset one, discovered later.
  final bool isPath;

  bool get isRequired => need == Need.required;
}

/// Works out which secrets a config implies.
///
/// This is the payoff of the `*_ref` convention: because `taxiway.yaml` names
/// every credential rather than holding one, the complete list of what a
/// project needs can be derived from it. One derivation then drives the
/// pre-flight check, the listing, and — later — the generated CI `env:` block.
abstract final class SecretRequirements {
  /// Everything [config] implies, for [environment].
  ///
  /// The environment matters because some entries are only meaningful in one:
  /// a keychain password is needed exactly where taxiway creates a keychain,
  /// and an Apple ID is an interactive-login fallback a runner must never take.
  static List<SecretRequirement> of(
    TaxiwayConfig config, {
    required RunEnvironment environment,
    String? appId,
  }) {
    final app = config.appOrNull(appId ?? config.defaultAppId);
    if (app == null) return const <SecretRequirement>[];

    final requirements = <SecretRequirement>[];
    void add(String name, Need need, String wantedBy, {bool isPath = false}) =>
        requirements.add(
          SecretRequirement(
            name: name,
            need: need,
            wantedBy: wantedBy,
            isPath: isPath,
          ),
        );

    final iosSigning = app.signing.ios;
    if (iosSigning?.matchGitUrl != null) {
      add(
        SecretNames.matchPassword,
        Need.required,
        'the certificates lane, to decrypt the match repository',
      );
      add(
        SecretNames.matchGitUrl,
        Need.optional,
        'overrides signing.ios.match_git_url',
      );
      add(SecretNames.matchGitBranch, Need.optional, 'the match repository');

      // A runner has neither a credential helper nor an SSH agent, so the
      // clone needs an explicit credential. Which one depends on the URL,
      // and they are mutually exclusive in match.
      if (!environment.mayPrompt) {
        final url = iosSigning!.matchGitUrl!;
        final overSsh = url.startsWith('git@') || url.startsWith('ssh://');
        add(
          overSsh
              ? SecretNames.matchGitPrivateKey
              : SecretNames.matchGitBasicAuthorization,
          Need.required,
          overSsh
              ? 'cloning the match repository over SSH'
              : 'cloning the match repository over HTTPS',
        );
      }
    }

    // Named in the config, so the variable is only a fallback for it.
    add(
      SecretNames.developerPortalTeamId,
      iosSigning?.teamId == null && app.ios != null
          ? Need.required
          : Need.optional,
      iosSigning?.teamId == null
          ? 'the iOS export, which has no signing.ios.team_id to fall back on'
          : 'overrides signing.ios.team_id',
    );

    final apiKey = iosSigning?.apiKey;
    for (final entry in <String, String?>{
      'signing.ios.api_key.key_id_ref': apiKey?.keyIdRef,
      'signing.ios.api_key.issuer_id_ref': apiKey?.issuerIdRef,
      'signing.ios.api_key.p8_ref': apiKey?.p8Ref,
    }.entries) {
      final name = entry.value;
      if (name != null) add(name, Need.required, entry.key);
    }

    // Only useful for the interactive login path, which is exactly the path a
    // runner must not take.
    if (environment.mayPrompt) {
      add(
        SecretNames.appleId,
        Need.optional,
        'interactive App Store Connect login',
      );
      add(
        SecretNames.appStoreConnectTeamId,
        Need.optional,
        'interactive App Store Connect login',
      );
    }

    final android = app.signing.android;
    if (android?.keystoreRef != null) {
      add(android!.keystoreRef!, Need.required, 'signing.android.keystore_ref');
    }
    final keyProperties = android?.keyProperties;
    for (final entry in <String, String?>{
      'signing.android.key_properties.store_password_ref':
          keyProperties?.storePasswordRef,
      'signing.android.key_properties.key_password_ref':
          keyProperties?.keyPasswordRef,
    }.entries) {
      final name = entry.value;
      if (name != null) add(name, Need.required, entry.key);
    }

    if (app.targets.play != null) {
      add(
        app.targets.play!.serviceAccountRef ??
            SecretNames.playServiceAccountPath,
        Need.required,
        'the play lane',
        isPath: app.targets.play!.serviceAccountRef == null,
      );
    }

    final firebase = app.targets.firebase;
    if (firebase != null) {
      add(
        SecretNames.firebaseServiceAccountPath,
        Need.required,
        'the firebase lane',
        isPath: true,
      );
      for (final ref in <String?>[
        firebase.androidAppIdRef,
        firebase.iosAppIdRef,
      ]) {
        if (ref != null) add(ref, Need.required, 'targets.firebase');
      }
    }

    final slack = config.notify.slackWebhookRef;
    if (slack != null) add(slack, Need.optional, 'notify.slack_webhook_ref');

    // taxiway creates a keychain exactly where it may not use the login one.
    if (!environment.mayUseLoginKeychain && app.ios != null) {
      add(
        SecretNames.keychainPassword,
        Need.optional,
        'the keychain taxiway creates off-workstation; generated when unset',
      );
    }

    return _deduplicate(requirements);
  }

  /// Keeps the strongest need and the first reason when a name is asked for
  /// twice, so a variable that is optional in one place and required in
  /// another is reported as required.
  static List<SecretRequirement> _deduplicate(
    List<SecretRequirement> requirements,
  ) {
    final byName = <String, SecretRequirement>{};
    for (final requirement in requirements) {
      final existing = byName[requirement.name];
      if (existing == null) {
        byName[requirement.name] = requirement;
        continue;
      }
      if (!existing.isRequired && requirement.isRequired) {
        byName[requirement.name] = requirement;
      }
    }
    return byName.values.toList()..sort((a, b) {
      if (a.isRequired != b.isRequired) return a.isRequired ? -1 : 1;
      return a.name.compareTo(b.name);
    });
  }
}
