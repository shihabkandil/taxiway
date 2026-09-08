/// One `.xcscheme`.
class IosScheme {
  const IosScheme({
    required this.name,
    required this.shared,
    this.buildConfiguration,
    this.testConfiguration,
    this.profileConfiguration,
    this.archiveConfiguration,
    this.owner,
  });

  final String name;

  /// True when the scheme lives in `xcshareddata/xcschemes/`.
  ///
  /// A scheme found only in `xcuserdata` is per-user and git-ignored, so the
  /// flavor works for its author and silently breaks for everyone else. That is
  /// a very common real-world bug, and reporting it is the point of recording
  /// this flag rather than merging the two directories.
  final bool shared;

  /// Configuration used by the Run action.
  final String? buildConfiguration;

  final String? testConfiguration;
  final String? profileConfiguration;

  /// Configuration used by the Archive action — the one that ships.
  final String? archiveConfiguration;

  /// For a user scheme, whose `xcuserdata` directory it came from.
  final String? owner;

  /// Every configuration this scheme names, deduplicated.
  Set<String> get referencedConfigurations => <String>{
    if (buildConfiguration != null) buildConfiguration!,
    if (testConfiguration != null) testConfiguration!,
    if (profileConfiguration != null) profileConfiguration!,
    if (archiveConfiguration != null) archiveConfiguration!,
  };

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'shared': shared,
    if (owner != null) 'owner': owner,
    if (buildConfiguration != null) 'buildConfiguration': buildConfiguration,
    if (testConfiguration != null) 'testConfiguration': testConfiguration,
    if (profileConfiguration != null)
      'profileConfiguration': profileConfiguration,
    if (archiveConfiguration != null)
      'archiveConfiguration': archiveConfiguration,
  };
}

/// One build configuration on a target.
class IosBuildConfiguration {
  const IosBuildConfiguration({
    required this.name,
    this.bundleIdentifier,
    this.productName,
    this.displayName,
    this.developmentTeam,
    this.infoPlistFile,
    this.baseConfigurationReference,
    this.settings = const <String, String>{},
  });

  final String name;

  /// `PRODUCT_BUNDLE_IDENTIFIER`, resolved through the xcconfig chain where the
  /// build setting is a `$(...)` reference.
  final String? bundleIdentifier;

  final String? productName;

  /// `APP_DISPLAY_NAME`, where a flavor setup defines one.
  final String? displayName;

  final String? developmentTeam;
  final String? infoPlistFile;

  /// Path of the xcconfig underneath this configuration, if any.
  final String? baseConfigurationReference;

  /// Every build setting, kept whole so adoption can show a faithful diff.
  final Map<String, String> settings;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    if (bundleIdentifier != null) 'bundleIdentifier': bundleIdentifier,
    if (productName != null) 'productName': productName,
    if (displayName != null) 'displayName': displayName,
    if (developmentTeam != null) 'developmentTeam': developmentTeam,
    if (infoPlistFile != null) 'infoPlistFile': infoPlistFile,
    if (baseConfigurationReference != null)
      'baseConfigurationReference': baseConfigurationReference,
  };
}

/// A shell script build phase, recorded because an existing flavor setup
/// usually copies a per-flavor `GoogleService-Info.plist` from one, and
/// overwriting it would silently break Firebase.
class IosShellScriptPhase {
  const IosShellScriptPhase({
    required this.name,
    required this.script,
    this.inputPaths = const <String>[],
    this.outputPaths = const <String>[],
  });

  final String? name;
  final String script;
  final List<String> inputPaths;
  final List<String> outputPaths;

  /// True when this looks like a per-flavor Firebase plist copy step.
  bool get looksLikeFirebaseCopy =>
      script.contains('GoogleService-Info') ||
      inputPaths.any((p) => p.contains('GoogleService-Info'));

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (name != null) 'name': name,
    'looksLikeFirebaseCopy': looksLikeFirebaseCopy,
  };
}

class IosTarget {
  const IosTarget({
    required this.name,
    this.productType,
    this.buildConfigurations = const <String, IosBuildConfiguration>{},
    this.shellScriptPhases = const <IosShellScriptPhase>[],
  });

  final String name;
  final String? productType;
  final Map<String, IosBuildConfiguration> buildConfigurations;
  final List<IosShellScriptPhase> shellScriptPhases;

  /// True for the app target itself, as opposed to test bundles and extensions.
  bool get isApplication => productType == 'com.apple.product-type.application';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    if (productType != null) 'productType': productType,
    'buildConfigurations': <String, dynamic>{
      for (final key in buildConfigurations.keys.toList()..sort())
        key: buildConfigurations[key]!.toJson(),
    },
    'shellScriptPhases': shellScriptPhases.map((p) => p.toJson()).toList(),
  };
}

/// What `ios/Runner.xcodeproj` says.
class IosModel {
  const IosModel({
    required this.objectVersion,
    this.targets = const <String, IosTarget>{},
    this.projectConfigurations = const <String>[],
    this.schemes = const <String, IosScheme>{},
    this.xcconfigs = const <String, Map<String, String>>{},
    this.deploymentTarget,
  });

  const IosModel.absent()
    : objectVersion = null,
      targets = const <String, IosTarget>{},
      projectConfigurations = const <String>[],
      schemes = const <String, IosScheme>{},
      xcconfigs = const <String, Map<String, String>>{},
      deploymentTarget = null;

  final int? objectVersion;
  final Map<String, IosTarget> targets;

  /// Configuration names declared at project level, which is the authoritative
  /// list — a target may omit one the project declares.
  final List<String> projectConfigurations;

  final Map<String, IosScheme> schemes;

  /// Resolved key/value pairs per xcconfig file, `#include` chains followed.
  final Map<String, Map<String, String>> xcconfigs;

  final String? deploymentTarget;

  bool get exists => objectVersion != null;

  /// The app target, which is what flavors are about.
  IosTarget? get applicationTarget {
    for (final target in targets.values) {
      if (target.isApplication) return target;
    }
    return targets['Runner'];
  }

  /// Xcode 16+ synchronized folders make mutation more fragile.
  bool get usesSynchronizedFolders =>
      objectVersion != null && objectVersion! >= 70;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'objectVersion': objectVersion,
    if (deploymentTarget != null) 'deploymentTarget': deploymentTarget,
    'projectConfigurations': projectConfigurations,
    'targets': <String, dynamic>{
      for (final key in targets.keys.toList()..sort())
        key: targets[key]!.toJson(),
    },
    'schemes': <String, dynamic>{
      for (final key in schemes.keys.toList()..sort())
        key: schemes[key]!.toJson(),
    },
    'xcconfigs': <String, dynamic>{
      for (final key in xcconfigs.keys.toList()..sort())
        key: <String, dynamic>{
          for (final setting in xcconfigs[key]!.keys.toList()..sort())
            setting: xcconfigs[key]![setting],
        },
    },
  };
}
