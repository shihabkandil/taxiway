import '../core/io/process_runner.dart';
import '../core/model/firebase_model.dart';
import '../core/model/ios_model.dart';
import '../core/model/project_model.dart';
import '../core/model/uncertainty.dart';
import 'android_inspector.dart';
import 'dart_inspector.dart';
import 'fastlane_inspector.dart';
import 'firebase_inspector.dart';
import 'ios_inspector.dart';
import 'xcodeproj_bridge.dart';

/// Reads a whole project into a [ProjectModel].
///
/// The `readFromDisk` half of the two-directional contract. It reads and
/// describes; it never writes, which is what makes `taxiway import` safe to run
/// on a working project.
class ProjectInspector {
  ProjectInspector({
    required this.runner,
    String? bridgeScriptPath,
    this.android = const AndroidInspector(),
    this.dart = const DartInspector(),
    this.fastlane = const FastlaneInspector(),
    this.firebase = const FirebaseInspector(),
  }) : _bridgeScriptPath = bridgeScriptPath ?? XcodeprojBridge.locateScript();

  final ProcessRunner runner;
  final AndroidInspector android;
  final DartInspector dart;
  final FastlaneInspector fastlane;
  final FirebaseInspector firebase;

  final String? _bridgeScriptPath;

  Future<ProjectModel> readFromDisk(String root, {bool deep = false}) async {
    final log = UncertaintyLog();

    final androidResult = await android.inspect(root);
    log.addAll(androidResult.uncertainties);

    final iosResult = await _inspectIos(root, log);
    log.addAll(iosResult.uncertainties);

    final dartResult = await dart.inspect(root);
    log.addAll(dartResult.uncertainties);

    final fastlaneResult = await fastlane.inspect(root);
    log.addAll(fastlaneResult.uncertainties);

    // Built before the Firebase read so gaps can be reported per flavor.
    var model = ProjectModel(
      root: root,
      android: androidResult.android,
      ios: iosResult.ios,
      dart: dartResult.dart,
      // Replaced below; Firebase is read last so it can report gaps per
      // flavor, which needs the flavor list this model provides.
      firebase: const FirebaseModel(),
      fastlane: fastlaneResult.setups,
    );

    final firebaseResult = await firebase.inspect(
      root,
      flavors: model.allFlavors,
    );
    log.addAll(firebaseResult.uncertainties);
    model = model.copyWith(firebase: firebaseResult.firebase);

    log.addAll(_crossPlatformFindings(model));

    return model.copyWith(uncertainties: log.build());
  }

  Future<IosInspectResult> _inspectIos(String root, UncertaintyLog log) async {
    final scriptPath = _bridgeScriptPath;
    if (scriptPath == null) {
      return IosInspectResult(
        ios: const IosModel.absent(),
        uncertainties: <Uncertainty>[
          const Uncertainty(
            field: 'ios',
            reason:
                'taxiway could not find its own Xcode project bridge '
                '(tool/ruby/xcodeproj_bridge.rb).',
            remedy:
                'Reinstall taxiway. This is a packaging bug, not a problem '
                'with your project.',
            severity: UncertaintySeverity.defect,
          ),
        ],
      );
    }
    return IosInspector(
      bridge: XcodeprojBridge(runner: runner, scriptPath: scriptPath),
    ).inspect(root);
  }

  /// Findings that only exist when both platforms are read together.
  ///
  /// A flavor on one platform and not the other builds on one and fails on the
  /// other, which nobody notices until a release.
  List<Uncertainty> _crossPlatformFindings(ProjectModel model) {
    final findings = <Uncertainty>[];
    if (!model.android.exists || !model.ios.exists) return findings;

    // A flavor whose name differs only by case is the single most confusing
    // version of this: both platforms look configured, and `flutter build
    // --flavor dev` matches Android but not Xcode. Reporting it as one finding
    // is far clearer than two "missing on the other platform" findings.
    final casingMismatches = <String, String>{};
    for (final androidFlavor in model.androidOnlyFlavors) {
      for (final iosFlavor in model.iosOnlyFlavors) {
        if (androidFlavor.toLowerCase() == iosFlavor.toLowerCase()) {
          casingMismatches[androidFlavor] = iosFlavor;
        }
      }
    }
    for (final entry in casingMismatches.entries) {
      findings.add(
        Uncertainty(
          field: 'flavors.${entry.key}',
          reason:
              'is named `${entry.key}` on Android but `${entry.value}` on '
              'iOS. Flutter matches flavor names case-sensitively, so one of '
              'the two never builds.',
          remedy:
              'Rename the iOS build configurations to '
              '${ProjectModel.configurationNamesFor(entry.key).join(', ')}, or '
              'rename the Android product flavor to `${entry.value}`.',
          severity: UncertaintySeverity.defect,
        ),
      );
    }

    for (final flavor in model.androidOnlyFlavors) {
      if (casingMismatches.containsKey(flavor)) continue;
      findings.add(
        Uncertainty(
          field: 'flavors.$flavor',
          reason:
              'is declared on Android but has no iOS build '
              'configurations.',
          remedy:
              'Add ${ProjectModel.configurationNamesFor(flavor).join(', ')} '
              'in Xcode, or remove the flavor from Gradle.',
          severity: UncertaintySeverity.defect,
        ),
      );
    }
    for (final flavor in model.iosOnlyFlavors) {
      if (casingMismatches.containsValue(flavor)) continue;
      findings.add(
        Uncertainty(
          field: 'flavors.$flavor',
          reason:
              'has iOS build configurations but is not declared as an '
              'Android product flavor.',
          remedy:
              'Add it to `productFlavors` in '
              '${model.android.buildFilePath ?? 'the app build file'}, or '
              'remove the iOS configurations.',
          severity: UncertaintySeverity.defect,
        ),
      );
    }

    // An entrypoint is how `flutter build --flavor` knows what to run; without
    // one the flavor builds the default app under a flavored bundle id, which
    // looks like it worked.
    for (final flavor in model.allFlavors) {
      if (model.dart.entrypointFor(flavor) == null &&
          model.dart.entrypoints.isNotEmpty) {
        findings.add(
          Uncertainty(
            field: 'dart.entrypoints.$flavor',
            reason:
                'no `lib/main_$flavor.dart` was found for flavor '
                '`$flavor`, and none of the existing entrypoints '
                '(${model.dart.entrypoints.keys.map((e) => 'main_$e.dart').join(', ')}) '
                'matches it by name.',
            remedy:
                'Create lib/main_$flavor.dart, or set this flavor\'s '
                'entrypoint manually in taxiway.yaml.',
            severity: UncertaintySeverity.defect,
          ),
        );
      }
    }
    return findings;
  }
}
