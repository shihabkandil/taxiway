/// Environment-variable names the generated lanes read.
///
/// Defined once because two things have to agree exactly: the Fastfile that
/// reads a variable, and `taxiway secrets check` that verifies it is set. A
/// pre-flight that checks `MATCH_PASSWORD` while the lane reads
/// `MATCH_PASSPHRASE` is worse than no pre-flight at all — it reports green and
/// the build still fails. A shared constant makes them the same string by
/// construction, and a test asserts every name here appears in the rendered
/// output.
///
/// Names taken from a `*_ref` field in `taxiway.yaml` are *not* here: those are
/// chosen by the user and read from the config.
abstract final class SecretNames {
  /// The passphrase the match repository is encrypted with.
  static const String matchPassword = 'MATCH_PASSWORD';

  /// Overrides the match repo the config names.
  static const String matchGitUrl = 'MATCH_GIT_URL';
  static const String matchGitBranch = 'MATCH_GIT_BRANCH';

  /// The Apple Developer Portal team. Not a secret — it appears in every build
  /// log — but it must be resolvable, so it is tracked alongside the rest.
  static const String developerPortalTeamId = 'DEVELOPER_PORTAL_TEAM_ID';

  /// Optional: only needed for the interactive Apple ID login path, which a
  /// runner should never take.
  static const String appleId = 'FASTLANE_APPLE_ID';
  static const String appStoreConnectTeamId = 'APP_STORE_CONNECT_TEAM_ID';

  /// Path to the Play service-account JSON.
  static const String playServiceAccountPath = 'PLAY_SERVICE_ACCOUNT_JSON_PATH';

  /// Path to the Firebase service-account JSON. A file, not the deprecated CI
  /// token, which App Distribution no longer accepts.
  static const String firebaseServiceAccountPath =
      'FIREBASE_SERVICE_ACCOUNT_JSON_PATH';

  /// Password for the dedicated keychain taxiway creates off-workstation.
  static const String keychainPassword = 'TAXIWAY_KEYCHAIN_PASSWORD';

  /// Every name taxiway itself defines, for tests and documentation.
  static const List<String> all = <String>[
    matchPassword,
    matchGitUrl,
    matchGitBranch,
    developerPortalTeamId,
    appleId,
    appStoreConnectTeamId,
    playServiceAccountPath,
    firebaseServiceAccountPath,
    keychainPassword,
  ];
}
