import '../core/config/shipway_config.dart';
import '../core/model/android_model.dart';
import '../core/model/dart_model.dart';
import '../core/model/firebase_model.dart';
import '../core/model/ios_model.dart';
import '../core/model/project_model.dart';

/// Builds the [ProjectModel] a config describes.
///
/// The `projectFromConfig` half of the two-directional contract: what the
/// project *would* look like if it matched `shipway.yaml`. Comparing this
/// against `readFromDisk` is what makes drift detection semantic.
abstract final class ProjectFromConfig {
  static ProjectModel build(
    ShipwayConfig config, {
    required String root,
    String? appId,
    GradleDsl gradleDsl = GradleDsl.kotlin,
  }) {
    final app = config.appOrNull(appId);
    if (app == null) {
      return ProjectModel(
        root: root,
        android: const AndroidModel.absent(),
        ios: const IosModel.absent(),
        dart: const DartModel(),
        firebase: const FirebaseModel(),
      );
    }

    return ProjectModel(
      root: root,
      android: _android(config, app, gradleDsl),
      ios: _ios(app),
      dart: _dart(config, app),
      firebase: _firebase(app),
    );
  }

  static AndroidModel _android(
    ShipwayConfig config,
    AppConfig app,
    GradleDsl dsl,
  ) {
    final applicationId = app.android?.applicationId;
    return AndroidModel(
      gradleDsl: dsl,
      buildFilePath: 'android/app/${dsl.buildFileName}',
      applicationId: applicationId,
      // A single dimension is what shipway generates; a project using more is
      // describing something shipway did not write.
      flavorDimensions: app.flavors.isEmpty
          ? const <String>[]
          : const <String>['environment'],
      flavors: <String, AndroidFlavor>{
        for (final entry in app.flavors.entries)
          entry.key: AndroidFlavor(
            name: entry.key,
            dimension: entry.value.dimension ?? 'environment',
            applicationIdSuffix: entry.value.suffix.isEmpty
                ? null
                : entry.value.suffix,
            versionNameSuffix: entry.value.versionNameSuffix,
            resValues: <String, String>{
              if (entry.value.displayName != null)
                'app_name': entry.value.displayName!,
            },
          ),
      },
      sourceSets: app.flavors.keys.toList()..sort(),
    );
  }

  static IosModel _ios(AppConfig app) {
    final bundleId = app.ios?.bundleId;
    if (bundleId == null && app.flavors.isEmpty) return const IosModel.absent();

    final configurations = <String, IosBuildConfiguration>{};
    final schemes = <String, IosScheme>{};

    for (final buildType in flutterBuildTypes) {
      configurations[buildType] = IosBuildConfiguration(
        name: buildType,
        bundleIdentifier: bundleId,
      );
    }

    for (final entry in app.flavors.entries) {
      final flavored = bundleId == null
          ? null
          : '$bundleId${entry.value.suffix}';
      for (final buildType in flutterBuildTypes) {
        final name = '$buildType-${entry.key}';
        configurations[name] = IosBuildConfiguration(
          name: name,
          bundleIdentifier: flavored,
          displayName: entry.value.displayName,
        );
      }
      // shipway always writes schemes shared, never to xcuserdata.
      schemes[entry.key] = IosScheme(
        name: entry.key,
        shared: true,
        buildConfiguration: 'Debug-${entry.key}',
        testConfiguration: 'Debug-${entry.key}',
        profileConfiguration: 'Profile-${entry.key}',
        archiveConfiguration: 'Release-${entry.key}',
      );
    }

    return IosModel(
      objectVersion: null,
      projectConfigurations: configurations.keys.toList(),
      targets: <String, IosTarget>{
        'Runner': IosTarget(
          name: 'Runner',
          productType: 'com.apple.product-type.application',
          buildConfigurations: configurations,
        ),
      },
      schemes: schemes,
    );
  }

  static DartModel _dart(ShipwayConfig config, AppConfig app) {
    final entrypoints = <String, DartEntrypoint>{};
    for (final entry in app.flavors.entries) {
      final path = entry.value.entrypoint ?? 'lib/main_${entry.key}.dart';
      entrypoints[entry.key] = DartEntrypoint(path: path, suffix: entry.key);
    }
    return DartModel(
      entrypoints: entrypoints,
      dartDefineFiles: <String, Map<String, String>>{
        for (final entry in app.flavors.entries)
          if (entry.value.dartDefines.isNotEmpty)
            entry.key: entry.value.dartDefines,
      },
      packageName: config.project.name,
    );
  }

  static FirebaseModel _firebase(AppConfig app) {
    final files = <FirebaseConfigFile>[];
    for (final entry in app.flavors.entries) {
      final firebase = entry.value.firebase;
      if (firebase == null) continue;
      if (firebase.android != null) {
        files.add(
          FirebaseConfigFile(
            path: firebase.android!,
            platform: 'android',
            sourceSet: entry.key,
          ),
        );
      }
      if (firebase.ios != null) {
        files.add(
          FirebaseConfigFile(
            path: firebase.ios!,
            platform: 'ios',
            sourceSet: entry.key,
          ),
        );
      }
    }
    return FirebaseModel(configFiles: files);
  }
}
