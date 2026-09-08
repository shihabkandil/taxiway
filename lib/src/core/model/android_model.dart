/// Which Gradle dialect a project is written in.
enum GradleDsl {
  /// `build.gradle.kts`
  kotlin('build.gradle.kts'),

  /// `build.gradle`
  groovy('build.gradle');

  const GradleDsl(this.buildFileName);

  final String buildFileName;

  static GradleDsl? forFileName(String name) => switch (name) {
    'build.gradle.kts' => GradleDsl.kotlin,
    'build.gradle' => GradleDsl.groovy,
    _ => null,
  };
}

/// One Android product flavor, as declared.
class AndroidFlavor {
  const AndroidFlavor({
    required this.name,
    this.dimension,
    this.applicationId,
    this.applicationIdSuffix,
    this.versionNameSuffix,
    this.signingConfig,
    this.resValues = const <String, String>{},
    this.manifestPlaceholders = const <String, String>{},
  });

  final String name;

  final String? dimension;

  /// A flavor may override the application id outright instead of suffixing it.
  final String? applicationId;

  final String? applicationIdSuffix;
  final String? versionNameSuffix;

  /// Name of the `signingConfigs` entry this flavor references, if any.
  final String? signingConfig;

  /// `resValue("string", key, value)` entries, keyed by name. `app_name` is the
  /// one taxiway cares about, but the rest are recorded so adoption can show a
  /// faithful diff.
  final Map<String, String> resValues;

  final Map<String, String> manifestPlaceholders;

  /// The application id this flavor produces, given the project's default.
  ///
  /// Null when it cannot be determined without guessing.
  String? effectiveApplicationId(String? defaultApplicationId) {
    final override = applicationId;
    if (override != null) return override;
    if (defaultApplicationId == null) return null;
    return '$defaultApplicationId${applicationIdSuffix ?? ''}';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    if (dimension != null) 'dimension': dimension,
    if (applicationId != null) 'applicationId': applicationId,
    if (applicationIdSuffix != null) 'applicationIdSuffix': applicationIdSuffix,
    if (versionNameSuffix != null) 'versionNameSuffix': versionNameSuffix,
    if (signingConfig != null) 'signingConfig': signingConfig,
    if (resValues.isNotEmpty) 'resValues': _sorted(resValues),
    if (manifestPlaceholders.isNotEmpty)
      'manifestPlaceholders': _sorted(manifestPlaceholders),
  };
}

/// A `signingConfigs { }` entry.
class AndroidSigningConfigDeclaration {
  const AndroidSigningConfigDeclaration({
    required this.name,
    this.storeFile,
    this.keyAlias,
    this.readsFromProperties = false,
  });

  final String name;

  /// Literal keystore path, when there is one.
  final String? storeFile;

  final String? keyAlias;

  /// True when the block reads from a properties file rather than literals.
  ///
  /// The common and correct shape, and the reason these fields are usually
  /// null: the values are deliberately not in the build file.
  final bool readsFromProperties;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    if (storeFile != null) 'storeFile': storeFile,
    if (keyAlias != null) 'keyAlias': keyAlias,
    'readsFromProperties': readsFromProperties,
  };
}

/// What `android { }` says.
class AndroidModel {
  const AndroidModel({
    required this.gradleDsl,
    this.applicationId,
    this.namespace,
    this.compileSdk,
    this.minSdk,
    this.targetSdk,
    this.flavorDimensions = const <String>[],
    this.flavors = const <String, AndroidFlavor>{},
    this.buildTypes = const <String>[],
    this.signingConfigs = const <String, AndroidSigningConfigDeclaration>{},
    this.sourceSets = const <String>[],
    this.buildFilePath,
  });

  /// An Android directory that is present but unreadable, or absent.
  const AndroidModel.absent()
    : gradleDsl = null,
      applicationId = null,
      namespace = null,
      compileSdk = null,
      minSdk = null,
      targetSdk = null,
      flavorDimensions = const <String>[],
      flavors = const <String, AndroidFlavor>{},
      buildTypes = const <String>[],
      signingConfigs = const <String, AndroidSigningConfigDeclaration>{},
      sourceSets = const <String>[],
      buildFilePath = null;

  final GradleDsl? gradleDsl;

  /// `defaultConfig.applicationId`.
  final String? applicationId;

  final String? namespace;
  final int? compileSdk;
  final int? minSdk;
  final int? targetSdk;

  final List<String> flavorDimensions;
  final Map<String, AndroidFlavor> flavors;
  final List<String> buildTypes;
  final Map<String, AndroidSigningConfigDeclaration> signingConfigs;

  /// Directory names under `android/app/src/`, which is where per-flavor
  /// resources and `google-services.json` live.
  final List<String> sourceSets;

  /// Relative path of the build file this was read from.
  final String? buildFilePath;

  bool get exists => gradleDsl != null;

  bool get hasFlavors => flavors.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'gradleDsl': gradleDsl?.name,
    if (buildFilePath != null) 'buildFilePath': buildFilePath,
    if (applicationId != null) 'applicationId': applicationId,
    if (namespace != null) 'namespace': namespace,
    if (compileSdk != null) 'compileSdk': compileSdk,
    if (minSdk != null) 'minSdk': minSdk,
    if (targetSdk != null) 'targetSdk': targetSdk,
    'flavorDimensions': flavorDimensions,
    'flavors': <String, dynamic>{
      for (final key in _sortedKeys(flavors)) key: flavors[key]!.toJson(),
    },
    'buildTypes': buildTypes,
    'signingConfigs': <String, dynamic>{
      for (final key in _sortedKeys(signingConfigs))
        key: signingConfigs[key]!.toJson(),
    },
    'sourceSets': sourceSets,
  };
}

List<String> _sortedKeys(Map<String, Object?> map) => map.keys.toList()..sort();

Map<String, String> _sorted(Map<String, String> map) => <String, String>{
  for (final key in map.keys.toList()..sort()) key: map[key]!,
};
