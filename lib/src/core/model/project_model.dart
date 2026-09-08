import 'android_model.dart';
import 'dart_model.dart';
import 'fastlane_model.dart';
import 'firebase_model.dart';
import 'ios_model.dart';
import 'uncertainty.dart';

/// Flutter's three required build types. An iOS flavor configuration is named
/// `<BuildType>-<flavor>`, and the flavor part is case-sensitive.
const List<String> flutterBuildTypes = <String>['Debug', 'Release', 'Profile'];

/// A faithful description of what a Flutter project's build configuration
/// actually is, independent of taxiway.
///
/// Both directions meet here: readers produce one from disk, `projectFromConfig`
/// produces one from `taxiway.yaml`, and `compare` diffs them. That is what
/// makes conflict detection semantic rather than textual.
class ProjectModel {
  const ProjectModel({
    required this.root,
    required this.android,
    required this.ios,
    required this.dart,
    required this.firebase,
    this.fastlane = const <FastlaneModel>[],
    this.uncertainties = const <Uncertainty>[],
  });

  /// Absolute path of the project root.
  final String root;

  final AndroidModel android;
  final IosModel ios;
  final DartModel dart;
  final FirebaseModel firebase;

  /// One per fastlane directory — a project may have `ios/fastlane` and
  /// `android/fastlane` independently.
  final List<FastlaneModel> fastlane;

  final List<Uncertainty> uncertainties;

  bool get hasFastlane => fastlane.isNotEmpty;

  /// Flavor names declared on Android.
  Set<String> get androidFlavors => android.flavors.keys.toSet();

  /// Flavor names inferred from iOS build configurations.
  ///
  /// By convention rather than declaration: iOS has no notion of a flavor, so
  /// they are the suffixes after `Debug|Release|Profile-`.
  Set<String> get iosFlavors {
    final names = <String>{};
    for (final configuration in _allConfigurationNames) {
      final flavor = flavorFromConfigurationName(configuration);
      if (flavor != null) names.add(flavor);
    }
    return names;
  }

  Set<String> get _allConfigurationNames => <String>{
    ...ios.projectConfigurations,
    for (final target in ios.targets.values) ...target.buildConfigurations.keys,
  };

  /// Every flavor known on either platform.
  Set<String> get allFlavors => <String>{...androidFlavors, ...iosFlavors};

  /// Flavors declared on Android but with no iOS configurations, and vice
  /// versa. A cross-platform gap builds fine on one platform and fails on the
  /// other, which is why import reports it explicitly.
  Set<String> get androidOnlyFlavors => androidFlavors.difference(iosFlavors);

  Set<String> get iosOnlyFlavors => iosFlavors.difference(androidFlavors);

  /// Splits an iOS configuration name into its build type and flavor.
  ///
  /// Returns null when the name is not `<BuildType>-<flavor>` — including when
  /// the case is wrong, because Flutter matches it case-sensitively and
  /// `Release-Dev` genuinely does not work.
  static String? flavorFromConfigurationName(String name) {
    for (final buildType in flutterBuildTypes) {
      final prefix = '$buildType-';
      if (name.startsWith(prefix) && name.length > prefix.length) {
        return name.substring(prefix.length);
      }
    }
    return null;
  }

  /// The configuration names a flavor requires on iOS.
  static List<String> configurationNamesFor(String flavor) => <String>[
    for (final type in flutterBuildTypes) '$type-$flavor',
  ];

  ProjectModel copyWith({
    AndroidModel? android,
    IosModel? ios,
    DartModel? dart,
    FirebaseModel? firebase,
    List<FastlaneModel>? fastlane,
    List<Uncertainty>? uncertainties,
  }) => ProjectModel(
    root: root,
    android: android ?? this.android,
    ios: ios ?? this.ios,
    dart: dart ?? this.dart,
    firebase: firebase ?? this.firebase,
    fastlane: fastlane ?? this.fastlane,
    uncertainties: uncertainties ?? this.uncertainties,
  );

  /// Stable JSON, used by golden tests and `--verbose` diagnostics.
  ///
  /// [root] is deliberately excluded: it is machine-specific and would make
  /// every golden fail on another checkout.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'android': android.toJson(),
    'ios': ios.toJson(),
    'dart': dart.toJson(),
    'firebase': firebase.toJson(),
    'fastlane': fastlane.map((f) => f.toJson()).toList(),
    'uncertainties': uncertainties.map((u) => u.toJson()).toList(),
  };
}
