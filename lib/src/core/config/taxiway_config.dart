import 'package:collection/collection.dart';
import 'package:json_annotation/json_annotation.dart';

part 'taxiway_config.g.dart';

/// The root of `taxiway.yaml`.
///
/// Every field is immutable and every collection is defaulted, so a minimal
/// config is genuinely minimal: `version`, `project.name`, one app, one flavor.
@JsonSerializable(anyMap: true, checked: true, disallowUnrecognizedKeys: true)
class TaxiwayConfig {
  const TaxiwayConfig({
    required this.version,
    required this.project,
    required this.apps,
    this.secrets = const SecretsConfig(),
    this.notify = const NotifyConfig(),
  });

  factory TaxiwayConfig.fromJson(Map<dynamic, dynamic> json) =>
      _$TaxiwayConfigFromJson(json);

  /// Schema version. Drives migrations; only 1 exists today.
  final int version;

  final ProjectConfig project;

  /// Keyed by app id. A single-app repo has one entry, conventionally `main`.
  ///
  /// Present from day one even though Phases 0-3 only read [defaultAppId]:
  /// retrofitting a monorepo shape onto a released schema is expensive, and
  /// carrying it now costs one map lookup.
  @JsonKey(fromJson: _appsFromJson)
  final Map<String, AppConfig> apps;

  final SecretsConfig secrets;
  final NotifyConfig notify;

  /// The app to act on when `--app` is not given.
  ///
  /// `main` if present, otherwise the sole entry; ambiguous only when there are
  /// several apps and none is named `main`, which the validator rejects.
  String? get defaultAppId {
    if (apps.containsKey('main')) return 'main';
    if (apps.length == 1) return apps.keys.first;
    return null;
  }

  AppConfig? appOrNull(String? id) => apps[id ?? defaultAppId];

  Map<String, dynamic> toJson() => _$TaxiwayConfigToJson(this);
}

@JsonSerializable(anyMap: true, checked: true, disallowUnrecognizedKeys: true)
class ProjectConfig {
  const ProjectConfig({
    required this.name,
    this.pubspec = 'pubspec.yaml',
    this.flutterMin,
  });

  factory ProjectConfig.fromJson(Map<dynamic, dynamic> json) =>
      _$ProjectConfigFromJson(json);

  final String name;

  /// Source of truth for version and build number.
  final String pubspec;

  /// Minimum Flutter version; `doctor` enforces it when set.
  @JsonKey(name: 'flutter_min')
  final String? flutterMin;

  Map<String, dynamic> toJson() => _$ProjectConfigToJson(this);
}

@JsonSerializable(anyMap: true, checked: true, disallowUnrecognizedKeys: true)
class AppConfig {
  const AppConfig({
    this.path = '.',
    this.flavors = const <String, FlavorConfig>{},
    this.signing = const SigningConfig(),
    this.targets = const TargetsConfig(),
    this.versioning = const VersioningConfig(),
  });

  factory AppConfig.fromJson(Map<dynamic, dynamic> json) =>
      _$AppConfigFromJson(json);

  /// Flutter app root, relative to the config file.
  final String path;

  @JsonKey(fromJson: _flavorsFromJson)
  final Map<String, FlavorConfig> flavors;
  final SigningConfig signing;
  final TargetsConfig targets;
  final VersioningConfig versioning;

  Map<String, dynamic> toJson() => _$AppConfigToJson(this);
}

@JsonSerializable(anyMap: true, checked: true, disallowUnrecognizedKeys: true)
class FlavorConfig {
  const FlavorConfig({
    this.suffix = '',
    this.displayName,
    this.dartDefines = const <String, String>{},
    this.icon,
    this.firebase,
  });

  factory FlavorConfig.fromJson(Map<dynamic, dynamic> json) =>
      _$FlavorConfigFromJson(json);

  /// Appended to the base bundle id / application id. Empty for production.
  final String suffix;

  @JsonKey(name: 'display_name')
  final String? displayName;

  @JsonKey(name: 'dart_defines')
  final Map<String, String> dartDefines;

  final String? icon;

  final FirebaseFlavorConfig? firebase;

  Map<String, dynamic> toJson() => _$FlavorConfigToJson(this);
}

@JsonSerializable(anyMap: true, checked: true, disallowUnrecognizedKeys: true)
class FirebaseFlavorConfig {
  const FirebaseFlavorConfig({this.android, this.ios});

  factory FirebaseFlavorConfig.fromJson(Map<dynamic, dynamic> json) =>
      _$FirebaseFlavorConfigFromJson(json);

  /// Path to this flavor's `google-services.json`.
  final String? android;

  /// Path to this flavor's `GoogleService-Info.plist`.
  final String? ios;

  Map<String, dynamic> toJson() => _$FirebaseFlavorConfigToJson(this);
}

@JsonSerializable(anyMap: true, checked: true, disallowUnrecognizedKeys: true)
class SigningConfig {
  const SigningConfig({this.ios, this.android});

  factory SigningConfig.fromJson(Map<dynamic, dynamic> json) =>
      _$SigningConfigFromJson(json);

  final IosSigningConfig? ios;
  final AndroidSigningConfig? android;

  Map<String, dynamic> toJson() => _$SigningConfigToJson(this);
}

/// How `match` storage is backed, mirroring fastlane's modes.
enum MatchStorage { git, googlecloud, s3 }

@JsonSerializable(anyMap: true, checked: true, disallowUnrecognizedKeys: true)
class IosSigningConfig {
  const IosSigningConfig({
    this.matchGitUrl,
    this.matchStorage = MatchStorage.git,
    this.teamId,
    this.apiKey,
  });

  factory IosSigningConfig.fromJson(Map<dynamic, dynamic> json) =>
      _$IosSigningConfigFromJson(json);

  @JsonKey(name: 'match_git_url')
  final String? matchGitUrl;

  @JsonKey(name: 'match_storage')
  final MatchStorage matchStorage;

  @JsonKey(name: 'team_id')
  final String? teamId;

  @JsonKey(name: 'api_key')
  final AscApiKeyConfig? apiKey;

  Map<String, dynamic> toJson() => _$IosSigningConfigToJson(this);
}

/// App Store Connect API key, by reference only.
///
/// Preferred over an Apple ID plus app-specific password: no 2FA session to go
/// stale, and it works with `match`, `pilot` and `deliver` alike.
@JsonSerializable(anyMap: true, checked: true, disallowUnrecognizedKeys: true)
class AscApiKeyConfig {
  const AscApiKeyConfig({this.keyIdRef, this.issuerIdRef, this.p8Ref});

  factory AscApiKeyConfig.fromJson(Map<dynamic, dynamic> json) =>
      _$AscApiKeyConfigFromJson(json);

  @JsonKey(name: 'key_id_ref')
  final String? keyIdRef;

  @JsonKey(name: 'issuer_id_ref')
  final String? issuerIdRef;

  /// Names the secret holding the base64-encoded `.p8`.
  @JsonKey(name: 'p8_ref')
  final String? p8Ref;

  Map<String, dynamic> toJson() => _$AscApiKeyConfigToJson(this);
}

@JsonSerializable(anyMap: true, checked: true, disallowUnrecognizedKeys: true)
class AndroidSigningConfig {
  const AndroidSigningConfig({this.keystoreRef, this.keyProperties});

  factory AndroidSigningConfig.fromJson(Map<dynamic, dynamic> json) =>
      _$AndroidSigningConfigFromJson(json);

  @JsonKey(name: 'keystore_ref')
  final String? keystoreRef;

  @JsonKey(name: 'key_properties')
  final KeyPropertiesConfig? keyProperties;

  Map<String, dynamic> toJson() => _$AndroidSigningConfigToJson(this);
}

@JsonSerializable(anyMap: true, checked: true, disallowUnrecognizedKeys: true)
class KeyPropertiesConfig {
  const KeyPropertiesConfig({
    this.storePasswordRef,
    this.keyPasswordRef,
    this.keyAlias = 'upload',
  });

  factory KeyPropertiesConfig.fromJson(Map<dynamic, dynamic> json) =>
      _$KeyPropertiesConfigFromJson(json);

  @JsonKey(name: 'store_password_ref')
  final String? storePasswordRef;

  @JsonKey(name: 'key_password_ref')
  final String? keyPasswordRef;

  /// The alias is not a secret, so it is a literal.
  @JsonKey(name: 'key_alias')
  final String keyAlias;

  Map<String, dynamic> toJson() => _$KeyPropertiesConfigToJson(this);
}

@JsonSerializable(anyMap: true, checked: true, disallowUnrecognizedKeys: true)
class TargetsConfig {
  const TargetsConfig({
    this.testflight,
    this.appstore,
    this.play,
    this.firebase,
  });

  factory TargetsConfig.fromJson(Map<dynamic, dynamic> json) =>
      _$TargetsConfigFromJson(json);

  final TestflightTarget? testflight;
  final AppstoreTarget? appstore;
  final PlayTarget? play;
  final FirebaseTarget? firebase;

  Map<String, dynamic> toJson() => _$TargetsConfigToJson(this);
}

/// Where a TestFlight changelog comes from.
enum ChangelogSource { git, file, prompt }

@JsonSerializable(anyMap: true, checked: true, disallowUnrecognizedKeys: true)
class TestflightTarget {
  const TestflightTarget({
    this.groups = const <String>[],
    this.distributeExternal = false,
    this.changelogFrom = ChangelogSource.git,
  });

  factory TestflightTarget.fromJson(Map<dynamic, dynamic> json) =>
      _$TestflightTargetFromJson(json);

  final List<String> groups;

  @JsonKey(name: 'distribute_external')
  final bool distributeExternal;

  @JsonKey(name: 'changelog_from')
  final ChangelogSource changelogFrom;

  Map<String, dynamic> toJson() => _$TestflightTargetToJson(this);
}

@JsonSerializable(anyMap: true, checked: true, disallowUnrecognizedKeys: true)
class AppstoreTarget {
  const AppstoreTarget({
    this.submitForReview = false,
    this.metadataPath,
  });

  factory AppstoreTarget.fromJson(Map<dynamic, dynamic> json) =>
      _$AppstoreTargetFromJson(json);

  @JsonKey(name: 'submit_for_review')
  final bool submitForReview;

  @JsonKey(name: 'metadata_path')
  final String? metadataPath;

  Map<String, dynamic> toJson() => _$AppstoreTargetToJson(this);
}

enum PlayTrack { internal, alpha, beta, production }

/// Play release status. Staged rollout requires `inProgress` plus a fractional
/// rollout; `supply` rejects the combination otherwise.
enum PlayReleaseStatus {
  draft,
  completed,
  @JsonValue('inProgress')
  inProgress,
  halted,
}

enum PlayArtifact { aab, apk }

@JsonSerializable(anyMap: true, checked: true, disallowUnrecognizedKeys: true)
class PlayTarget {
  const PlayTarget({
    this.track = PlayTrack.internal,
    this.releaseStatus = PlayReleaseStatus.draft,
    this.rollout,
    this.artifact = PlayArtifact.aab,
    this.serviceAccountRef,
  });

  factory PlayTarget.fromJson(Map<dynamic, dynamic> json) =>
      _$PlayTargetFromJson(json);

  final PlayTrack track;

  @JsonKey(name: 'release_status')
  final PlayReleaseStatus releaseStatus;

  /// `user_fraction` for a staged rollout, 0-1.
  final double? rollout;

  final PlayArtifact artifact;

  @JsonKey(name: 'service_account_ref')
  final String? serviceAccountRef;

  Map<String, dynamic> toJson() => _$PlayTargetToJson(this);
}

@JsonSerializable(anyMap: true, checked: true, disallowUnrecognizedKeys: true)
class FirebaseTarget {
  const FirebaseTarget({
    this.androidAppIdRef,
    this.iosAppIdRef,
    this.groups = const <String>[],
  });

  factory FirebaseTarget.fromJson(Map<dynamic, dynamic> json) =>
      _$FirebaseTargetFromJson(json);

  @JsonKey(name: 'android_app_id_ref')
  final String? androidAppIdRef;

  @JsonKey(name: 'ios_app_id_ref')
  final String? iosAppIdRef;

  final List<String> groups;

  Map<String, dynamic> toJson() => _$FirebaseTargetToJson(this);
}

/// How the build number is chosen.
enum VersioningStrategy {
  /// `yyMMddHHmm`.
  timestamp,

  /// Bump whatever `pubspec.yaml` says.
  increment,

  /// Ask the store for the latest build number and go one higher.
  remote,
}

@JsonSerializable(anyMap: true, checked: true, disallowUnrecognizedKeys: true)
class VersioningConfig {
  const VersioningConfig({
    this.strategy = VersioningStrategy.increment,
    this.syncIosAndroid = true,
  });

  factory VersioningConfig.fromJson(Map<dynamic, dynamic> json) =>
      _$VersioningConfigFromJson(json);

  final VersioningStrategy strategy;

  /// Keep `CFBundleVersion` equal to `versionCode`.
  @JsonKey(name: 'sync_ios_android')
  final bool syncIosAndroid;

  Map<String, dynamic> toJson() => _$VersioningConfigToJson(this);
}

@JsonSerializable(anyMap: true, checked: true, disallowUnrecognizedKeys: true)
class SecretsConfig {
  const SecretsConfig({this.dotenv = '.env.{flavor}', this.keychain = true});

  factory SecretsConfig.fromJson(Map<dynamic, dynamic> json) =>
      _$SecretsConfigFromJson(json);

  /// `{flavor}` is substituted at resolution time.
  final String dotenv;

  /// Whether the OS keychain participates in secret resolution.
  final bool keychain;

  Map<String, dynamic> toJson() => _$SecretsConfigToJson(this);
}

@JsonSerializable(anyMap: true, checked: true, disallowUnrecognizedKeys: true)
class NotifyConfig {
  const NotifyConfig({this.slackWebhookRef});

  factory NotifyConfig.fromJson(Map<dynamic, dynamic> json) =>
      _$NotifyConfigFromJson(json);

  @JsonKey(name: 'slack_webhook_ref')
  final String? slackWebhookRef;

  Map<String, dynamic> toJson() => _$NotifyConfigToJson(this);
}

/// A map entry written with no body — `main:` or `prod:` — is the natural way
/// to say "this exists and takes every default", so it must not be a type
/// error. YAML gives us a null value there; these turn it into an empty map.
Map<String, AppConfig> _appsFromJson(Map<dynamic, dynamic> json) =>
    _entriesFromJson(json, AppConfig.fromJson);

Map<String, FlavorConfig> _flavorsFromJson(Map<dynamic, dynamic> json) =>
    _entriesFromJson(json, FlavorConfig.fromJson);

Map<String, T> _entriesFromJson<T>(
  Map<dynamic, dynamic> json,
  T Function(Map<dynamic, dynamic>) build,
) =>
    <String, T>{
      for (final entry in json.entries)
        entry.key.toString(): build(
          entry.value == null
              ? const <dynamic, dynamic>{}
              : (entry.value as Map<dynamic, dynamic>),
        ),
    };

/// Every `*_ref` in a config, paired with the YAML path that carries it.
///
/// Used by the secret-shaped-value validator, by `secrets list`, and by import
/// when it harvests names from an existing fastlane setup.
Iterable<({String path, String? value})> secretRefsOf(TaxiwayConfig config) sync* {
  yield (path: 'notify.slack_webhook_ref', value: config.notify.slackWebhookRef);
  for (final app in config.apps.entries) {
    final base = 'apps.${app.key}';
    final ios = app.value.signing.ios;
    final android = app.value.signing.android;
    yield (path: '$base.signing.ios.api_key.key_id_ref', value: ios?.apiKey?.keyIdRef);
    yield (path: '$base.signing.ios.api_key.issuer_id_ref', value: ios?.apiKey?.issuerIdRef);
    yield (path: '$base.signing.ios.api_key.p8_ref', value: ios?.apiKey?.p8Ref);
    yield (path: '$base.signing.android.keystore_ref', value: android?.keystoreRef);
    yield (
      path: '$base.signing.android.key_properties.store_password_ref',
      value: android?.keyProperties?.storePasswordRef,
    );
    yield (
      path: '$base.signing.android.key_properties.key_password_ref',
      value: android?.keyProperties?.keyPasswordRef,
    );
    yield (
      path: '$base.targets.play.service_account_ref',
      value: app.value.targets.play?.serviceAccountRef,
    );
    yield (
      path: '$base.targets.firebase.android_app_id_ref',
      value: app.value.targets.firebase?.androidAppIdRef,
    );
    yield (
      path: '$base.targets.firebase.ios_app_id_ref',
      value: app.value.targets.firebase?.iosAppIdRef,
    );
  }
}

/// Deep equality helper used by round-trip tests.
const DeepCollectionEquality configEquality = DeepCollectionEquality();
