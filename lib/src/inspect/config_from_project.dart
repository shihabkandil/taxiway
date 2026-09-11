import '../core/config/shipway_config.dart';
import '../core/model/android_model.dart';
import '../core/model/fastlane_model.dart';
import '../core/model/project_model.dart';
import '../version.dart';

/// Derives a `shipway.yaml` from what a project actually is.
///
/// The `configFromProject` half of the two-directional contract. It writes down
/// only what the readers established: a field the readers could not resolve is
/// left out, so the config never asserts something that was guessed.
abstract final class ConfigFromProject {
  /// Conventional id for the single app in a non-monorepo project.
  static const String defaultAppId = 'main';

  /// The flavor dimension shipway generates.
  static const String _defaultDimension = 'environment';

  static ShipwayConfig build(ProjectModel model) {
    final flavors = _flavors(model);

    return ShipwayConfig(
      version: ConfigLoaderVersion.supported,
      project: ProjectConfig(
        name: model.dart.packageName ?? 'app',
        flutterMin: null,
      ),
      apps: <String, AppConfig>{
        defaultAppId: AppConfig(
          android: model.android.applicationId == null
              ? null
              : AndroidAppConfig(applicationId: model.android.applicationId),
          ios: _iosIdentity(model),
          flavors: flavors,
          signing: _signing(model),
          targets: const TargetsConfig(),
        ),
      },
      notify: const NotifyConfig(),
    );
  }

  static IosAppConfig? _iosIdentity(ProjectModel model) {
    final bundleId = _baseBundleId(model);
    return bundleId == null ? null : IosAppConfig(bundleId: bundleId);
  }

  /// The unflavored bundle id: whatever the plain `Release` configuration uses.
  ///
  /// Read from `Release` rather than derived by stripping a suffix, because the
  /// suffix is what we are trying to determine.
  static String? _baseBundleId(ProjectModel model) {
    final target = model.ios.applicationTarget;
    if (target == null) return null;
    for (final name in const <String>['Release', 'Debug', 'Profile']) {
      final id = target.buildConfigurations[name]?.bundleIdentifier;
      if (id != null) return id;
    }
    return null;
  }

  static Map<String, FlavorConfig> _flavors(ProjectModel model) {
    final names = model.allFlavors.toList()..sort();
    final result = <String, FlavorConfig>{};

    for (final name in names) {
      final androidFlavor = model.android.flavors[name];
      result[name] = FlavorConfig(
        suffix: _suffix(model, name),
        versionNameSuffix: androidFlavor?.versionNameSuffix,
        // Left implicit when it is the one shipway would generate anyway.
        dimension: androidFlavor?.dimension == _defaultDimension
            ? null
            : androidFlavor?.dimension,
        displayName: _displayName(model, name),
        entrypoint: _entrypoint(model, name),
        firebase: _firebase(model, name),
      );
    }
    return result;
  }

  /// The suffix this flavor appends to the base id.
  ///
  /// Android states it outright. iOS does not, so it is recovered by comparing
  /// the flavor's bundle id against the base — and only when the base is
  /// genuinely a prefix, since a flavor may override the id entirely.
  static String _suffix(ProjectModel model, String flavor) {
    final androidSuffix = model.android.flavors[flavor]?.applicationIdSuffix;
    if (androidSuffix != null) return androidSuffix;

    final base = _baseBundleId(model);
    final target = model.ios.applicationTarget;
    if (base != null && target != null) {
      final flavored =
          target.buildConfigurations['Release-$flavor']?.bundleIdentifier;
      if (flavored != null && flavored.startsWith(base)) {
        return flavored.substring(base.length);
      }
    }
    return '';
  }

  /// The flavor's display name, from Android's `app_name` string resource or
  /// the iOS display-name build setting.
  static String? _displayName(ProjectModel model, String flavor) {
    final fromAndroid = model.android.flavors[flavor]?.resValues['app_name'];
    if (fromAndroid != null) return fromAndroid;
    final target = model.ios.applicationTarget;
    return target?.buildConfigurations['Release-$flavor']?.displayName;
  }

  /// Recorded only when it differs from the `main_<flavor>.dart` default, so
  /// the config stays free of noise that restates the convention.
  static String? _entrypoint(ProjectModel model, String flavor) {
    final entrypoint = model.dart.entrypointFor(flavor);
    if (entrypoint == null) return null;
    final conventional = 'lib/main_$flavor.dart';
    return entrypoint.path == conventional ? null : entrypoint.path;
  }

  static FirebaseFlavorConfig? _firebase(ProjectModel model, String flavor) {
    String? pathFor(String platform) {
      for (final file in model.firebase.forPlatform(platform)) {
        if (file.sourceSet == flavor) return file.path;
      }
      // A directory named for the flavor's conventional short form, which is
      // how `development` ends up in `ios/config/dev/`.
      for (final file in model.firebase.forPlatform(platform)) {
        final sourceSet = file.sourceSet;
        if (sourceSet == null) continue;
        if (flavor.startsWith(sourceSet) && sourceSet.length >= 3) {
          return file.path;
        }
      }
      return null;
    }

    final android = pathFor('android');
    final ios = pathFor('ios');
    if (android == null && ios == null) return null;
    return FirebaseFlavorConfig(android: android, ios: ios);
  }

  /// Signing, seeded from an existing fastlane setup where there is one.
  ///
  /// Secret *names* are harvested rather than invented, so a user who already
  /// chose `ASC_KEY_ID` is not asked to choose it again.
  static SigningConfig _signing(ProjectModel model) {
    final ios = _iosSigning(model);
    final android = _androidSigning(model);
    if (ios == null && android == null) return const SigningConfig();
    return SigningConfig(ios: ios, android: android);
  }

  static IosSigningConfig? _iosSigning(ProjectModel model) {
    final fastlane = _fastlaneFor(model, 'ios');
    final teamId = fastlane?.teamId ?? _developmentTeam(model);
    final env = fastlane?.environmentVariables ?? const <String>{};

    final apiKey = _apiKeyRefs(env);
    final matchUrl = fastlane?.matchGitUrl;
    if (teamId == null && apiKey == null && matchUrl == null) return null;

    return IosSigningConfig(
      teamId: teamId,
      matchGitUrl: matchUrl,
      matchStorage: _matchStorage(fastlane?.matchStorageMode),
      apiKey: apiKey,
    );
  }

  static MatchStorage _matchStorage(String? mode) => switch (mode) {
    'googlecloud' => MatchStorage.googlecloud,
    's3' => MatchStorage.s3,
    _ => MatchStorage.git,
  };

  /// Picks out env var names that look like App Store Connect API key refs.
  static AscApiKeyConfig? _apiKeyRefs(Set<String> env) {
    String? find(List<String> needles) {
      for (final name in env) {
        final lower = name.toLowerCase();
        if (needles.every(lower.contains)) return name;
      }
      return null;
    }

    final keyId = find(<String>['key', 'id']);
    final issuerId = find(<String>['issuer']);
    final p8 = find(<String>['p8']) ?? find(<String>['key', 'content']);
    if (keyId == null && issuerId == null && p8 == null) return null;
    return AscApiKeyConfig(keyIdRef: keyId, issuerIdRef: issuerId, p8Ref: p8);
  }

  static AndroidSigningConfig? _androidSigning(ProjectModel model) {
    final fastlane = _fastlaneFor(model, 'android');
    final env = fastlane?.environmentVariables ?? const <String>{};

    String? find(List<String> needles) {
      for (final name in env) {
        final lower = name.toLowerCase();
        if (needles.every(lower.contains)) return name;
      }
      return null;
    }

    final signingConfig = model.android.signingConfigs.values
        .cast<AndroidSigningConfigDeclaration?>()
        .firstWhere((c) => c != null, orElse: () => null);

    final storePassword = find(<String>['store', 'password']);
    final keyPassword = find(<String>['key', 'password']);
    final keystore = find(<String>['keystore']);

    if (signingConfig == null &&
        storePassword == null &&
        keyPassword == null &&
        keystore == null) {
      return null;
    }

    return AndroidSigningConfig(
      keystoreRef: keystore,
      keyProperties: KeyPropertiesConfig(
        storePasswordRef: storePassword,
        keyPasswordRef: keyPassword,
        keyAlias: signingConfig?.keyAlias ?? 'upload',
      ),
    );
  }

  static String? _developmentTeam(ProjectModel model) {
    final target = model.ios.applicationTarget;
    if (target == null) return null;
    for (final config in target.buildConfigurations.values) {
      final team = config.developmentTeam;
      if (team != null && team.isNotEmpty) return team;
    }
    return null;
  }

  static FastlaneModel? _fastlaneFor(ProjectModel model, String platform) {
    for (final setup in model.fastlane) {
      if (setup.directory.startsWith(platform)) return setup;
    }
    return null;
  }
}

/// The config schema version this build writes.
abstract final class ConfigLoaderVersion {
  static const int supported = 1;

  /// Recorded in the generated file's header comment.
  static const String generator = packageVersion;
}
