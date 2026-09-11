import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/model/ios_model.dart';
import '../core/model/project_model.dart';
import '../core/model/uncertainty.dart';
import 'xcconfig_reader.dart';
import 'xcodeproj_bridge.dart';
import 'xcscheme_reader.dart';

class IosInspectResult {
  const IosInspectResult({required this.ios, required this.uncertainties});

  final IosModel ios;
  final List<Uncertainty> uncertainties;
}

/// Reads a project's iOS build configuration.
///
/// iOS has no notion of a flavor, so everything here is convention: flavors are
/// inferred from configuration names of the form `<BuildType>-<flavor>`. Names
/// that violate that shape are recorded as findings rather than silently
/// dropped, because they are usually the reason someone's flavor "doesn't work".
class IosInspector {
  const IosInspector({required this.bridge});

  final XcodeprojBridge bridge;

  static const String projectPath = 'ios/Runner.xcodeproj';
  static const String flutterDirectory = 'ios/Flutter';

  Future<IosInspectResult> inspect(String root) async {
    final log = UncertaintyLog();
    final absoluteProject = p.join(root, projectPath);

    if (!Directory(absoluteProject).existsSync()) {
      log.note(
        field: 'ios',
        reason: 'no $projectPath was found.',
        remedy:
            'If this project targets iOS, run `flutter create --platforms=ios .`.',
      );
      return IosInspectResult(
        ios: const IosModel.absent(),
        uncertainties: log.build(),
      );
    }

    final Map<String, dynamic> response;
    try {
      response = await bridge.read(absoluteProject);
    } on XcodeprojBridgeException catch (e) {
      log.add(
        Uncertainty(
          field: 'ios',
          reason: e.message,
          remedy:
              e.remedy ??
              'Fix the Ruby toolchain and re-run; `shipway doctor` checks it.',
          severity: UncertaintySeverity.defect,
          source: projectPath,
        ),
      );
      return IosInspectResult(
        ios: const IosModel.absent(),
        uncertainties: log.build(),
      );
    }

    final project =
        (response['project'] as Map<String, dynamic>?) ??
        const <String, dynamic>{};

    final xcconfigs = await XcconfigReader.readDirectory(
      root,
      flutterDirectory,
    );
    final schemes = await XcschemeReader.readAll(absoluteProject);

    final projectConfigurations = _configurationNames(
      (project['rootObject'] as Map<String, dynamic>?)?['buildConfigurations'],
    );

    final targets = <String, IosTarget>{};
    for (final raw
        in (project['targets'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>()) {
      final target = _readTarget(raw, root, xcconfigs, log);
      targets[target.name] = target;
    }

    final model = IosModel(
      objectVersion: (project['objectVersion'] as num?)?.toInt(),
      projectConfigurations: projectConfigurations,
      targets: targets,
      schemes: schemes,
      xcconfigs: xcconfigs,
      deploymentTarget: _deploymentTarget(targets),
    );

    _reportFindings(model, log);
    return IosInspectResult(ios: model, uncertainties: log.build());
  }

  IosTarget _readTarget(
    Map<String, dynamic> raw,
    String root,
    Map<String, Map<String, String>> xcconfigs,
    UncertaintyLog log,
  ) {
    final name = raw['name'] as String? ?? '(unnamed)';
    final configurations = <String, IosBuildConfiguration>{};

    for (final rawConfig
        in (raw['buildConfigurations'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>()) {
      final configName = rawConfig['name'] as String? ?? '(unnamed)';
      final settings =
          (rawConfig['buildSettings'] as Map<String, dynamic>? ??
                  const <String, dynamic>{})
              .map((k, v) => MapEntry(k, v.toString()));

      final baseReference = rawConfig['baseConfigurationReference'] as String?;
      // Settings inherited from the xcconfig underneath, which is where a
      // flavor's real bundle id often lives.
      final inherited = _settingsFromXcconfig(baseReference, root, xcconfigs);
      final merged = <String, String>{...inherited, ...settings};

      configurations[configName] = IosBuildConfiguration(
        name: configName,
        bundleIdentifier: _resolved(
          settings['PRODUCT_BUNDLE_IDENTIFIER'],
          merged,
          field: 'ios.targets.$name.$configName.PRODUCT_BUNDLE_IDENTIFIER',
          log: log,
        ),
        productName: merged['PRODUCT_NAME'],
        displayName:
            merged['APP_DISPLAY_NAME'] ??
            merged['INFOPLIST_KEY_CFBundleDisplayName'],
        developmentTeam: merged['DEVELOPMENT_TEAM'],
        infoPlistFile: merged['INFOPLIST_FILE'],
        baseConfigurationReference: baseReference == null
            ? null
            : _relative(baseReference, root),
        settings: merged,
      );
    }

    return IosTarget(
      name: name,
      productType: raw['productType'] as String? ?? raw['type'] as String?,
      buildConfigurations: configurations,
      shellScriptPhases: _readPhases(raw),
    );
  }

  List<IosShellScriptPhase> _readPhases(Map<String, dynamic> raw) {
    final phases = <IosShellScriptPhase>[];
    for (final phase
        in (raw['buildPhases'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>()) {
      if (phase['isa'] != 'PBXShellScriptBuildPhase') continue;
      phases.add(
        IosShellScriptPhase(
          name: phase['name'] as String?,
          script: phase['shellScript'] as String? ?? '',
          inputPaths: (phase['inputPaths'] as List<dynamic>? ?? const [])
              .cast<String>(),
          outputPaths: (phase['outputPaths'] as List<dynamic>? ?? const [])
              .cast<String>(),
        ),
      );
    }
    return phases;
  }

  Map<String, String> _settingsFromXcconfig(
    String? reference,
    String root,
    Map<String, Map<String, String>> xcconfigs,
  ) {
    if (reference == null) return const <String, String>{};
    final relative = _relative(reference, root);
    final direct = xcconfigs[relative];
    if (direct != null) return direct;
    // The reference may point outside ios/Flutter, e.g. at a Pods xcconfig.
    for (final entry in xcconfigs.entries) {
      if (p.basename(entry.key) == p.basename(relative)) return entry.value;
    }
    return const <String, String>{};
  }

  /// Resolves a `$(VAR)` build setting, recording an uncertainty if it cannot.
  String? _resolved(
    String? value,
    Map<String, String> settings, {
    required String field,
    required UncertaintyLog log,
  }) {
    if (value == null) return null;
    final resolved = XcconfigReader.resolve(value, settings);
    if (resolved != null) return resolved;
    log.nonLiteral(field: field, expression: value, source: projectPath);
    return null;
  }

  static List<String> _configurationNames(Object? raw) {
    if (raw is! List) return const <String>[];
    return raw
        .cast<Map<String, dynamic>>()
        .map((c) => c['name'] as String? ?? '')
        .where((n) => n.isNotEmpty)
        .toList();
  }

  static String? _deploymentTarget(Map<String, IosTarget> targets) {
    for (final target in targets.values) {
      for (final config in target.buildConfigurations.values) {
        final value = config.settings['IPHONEOS_DEPLOYMENT_TARGET'];
        if (value != null) return value;
      }
    }
    return null;
  }

  static String _relative(String path, String root) =>
      p.isWithin(root, path) ? p.relative(path, from: root) : path;

  /// Records convention violations: the things that make a flavor work for one
  /// person and fail for everyone else.
  void _reportFindings(IosModel model, UncertaintyLog log) {
    final target = model.applicationTarget;
    if (target == null) return;

    final configurationNames = <String>{
      ...model.projectConfigurations,
      ...target.buildConfigurations.keys,
    };
    final flavors = <String>{
      for (final name in configurationNames)
        if (ProjectModel.flavorFromConfigurationName(name) != null)
          ProjectModel.flavorFromConfigurationName(name)!,
    };

    // A configuration whose build type is cased wrong does not work: Flutter
    // matches `<BuildType>-<flavor>` case-sensitively.
    for (final name in configurationNames) {
      if (ProjectModel.flavorFromConfigurationName(name) != null) continue;
      if (flutterBuildTypes.contains(name)) continue;
      final miscased = flutterBuildTypes.firstWhere(
        (type) => name.toLowerCase().startsWith('${type.toLowerCase()}-'),
        orElse: () => '',
      );
      if (miscased.isNotEmpty) {
        log.defect(
          field: 'ios.buildConfigurations.$name',
          reason:
              'is named `$name`, but Flutter requires '
              '`<Debug|Release|Profile>-<flavor>` and matches it '
              'case-sensitively.',
          remedy:
              'Rename it to '
              '`$miscased-${name.substring(miscased.length + 1)}`.',
          source: projectPath,
        );
      }
    }

    // A flavor missing one of the three build types fails only in the mode it
    // is missing — typically Profile, discovered during a release build.
    for (final flavor in flavors) {
      final missing = ProjectModel.configurationNamesFor(
        flavor,
      ).where((name) => !configurationNames.contains(name)).toList();
      if (missing.isNotEmpty) {
        log.defect(
          field: 'ios.flavors.$flavor',
          reason:
              'is missing the ${missing.join(', ')} '
              'build configuration${missing.length == 1 ? '' : 's'}.',
          remedy:
              'Add ${missing.length == 1 ? 'it' : 'them'} in Xcode, or run '
              '`shipway generate flavors` once this project is adopted.',
          source: projectPath,
        );
      }
    }

    for (final scheme in model.schemes.values) {
      if (!scheme.shared) {
        log.defect(
          field: 'ios.schemes.${scheme.name}',
          reason:
              'exists only in xcuserdata'
              '${scheme.owner == null ? '' : ' (${scheme.owner})'}, which is '
              'per-user and git-ignored.',
          remedy:
              'Open the scheme in Xcode and tick "Shared", so it works for '
              'everyone on the team rather than only its author.',
          source: '$projectPath/xcuserdata',
        );
      }
      // A scheme pointing at a configuration that no longer exists builds with
      // Xcode's fallback instead, silently producing the wrong flavor.
      for (final referenced in scheme.referencedConfigurations) {
        if (!configurationNames.contains(referenced)) {
          log.defect(
            field: 'ios.schemes.${scheme.name}',
            reason:
                'references build configuration `$referenced`, which does '
                'not exist.',
            remedy: 'Point the scheme at an existing configuration in Xcode.',
            source: projectPath,
          );
        }
      }
    }

    // A flavor with no scheme cannot be selected, so `flutter build --flavor`
    // fails with a message that does not mention schemes at all.
    for (final flavor in flavors) {
      final hasScheme = model.schemes.values.any(
        (s) =>
            s.name == flavor ||
            s.referencedConfigurations.any(
              (c) => ProjectModel.flavorFromConfigurationName(c) == flavor,
            ),
      );
      if (!hasScheme) {
        log.defect(
          field: 'ios.schemes',
          reason:
              'flavor `$flavor` has build configurations but no scheme '
              'that uses them.',
          remedy: 'Create a shared scheme named `$flavor` in Xcode.',
          source: '$projectPath/${XcschemeReader.sharedDirectory}',
        );
      }
    }
  }
}
