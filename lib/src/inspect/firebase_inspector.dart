import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/model/firebase_model.dart';
import '../core/model/uncertainty.dart';

class FirebaseInspectResult {
  const FirebaseInspectResult({
    required this.firebase,
    required this.uncertainties,
  });

  final FirebaseModel firebase;
  final List<Uncertainty> uncertainties;
}

/// Finds per-flavor Firebase configuration.
///
/// Correlating these with flavors is the point: a project with a
/// `google-services.json` for one flavor and not another builds fine and fails
/// at runtime, which is exactly the kind of thing import should say out loud.
class FirebaseInspector {
  const FirebaseInspector();

  static const String androidFileName = 'google-services.json';
  static const String iosFileName = 'GoogleService-Info.plist';

  Future<FirebaseInspectResult> inspect(
    String root, {
    Set<String> flavors = const <String>{},
  }) async {
    final log = UncertaintyLog();
    final files = <FirebaseConfigFile>[
      ...await _readAndroid(root),
      ...await _readIos(root),
    ];

    final model = FirebaseModel(
      configFiles: files,
      hasFirebaseJson: File(p.join(root, 'firebase.json')).existsSync(),
      hasFirebaseOptionsDart: File(
        p.join(root, 'lib/firebase_options.dart'),
      ).existsSync(),
    );

    if (model.inUse) _reportGaps(model, flavors, log);
    return FirebaseInspectResult(firebase: model, uncertainties: log.build());
  }

  Future<List<FirebaseConfigFile>> _readAndroid(String root) async {
    final files = <FirebaseConfigFile>[];

    Future<void> consider(File file, String? sourceSet) async {
      if (!file.existsSync()) return;
      final json = await _decode(file);
      files.add(
        FirebaseConfigFile(
          path: p.relative(file.path, from: root),
          platform: 'android',
          sourceSet: sourceSet,
          projectId: _projectId(json),
          bundleOrPackageId: _androidPackage(json),
          appId: _androidAppId(json),
        ),
      );
    }

    await consider(File(p.join(root, 'android/app', androidFileName)), null);

    final src = Directory(p.join(root, 'android/app/src'));
    if (src.existsSync()) {
      for (final dir in src.listSync().whereType<Directory>()) {
        await consider(
          File(p.join(dir.path, androidFileName)),
          p.basename(dir.path),
        );
      }
    }
    return files;
  }

  Future<List<FirebaseConfigFile>> _readIos(String root) async {
    final ios = Directory(p.join(root, 'ios'));
    if (!ios.existsSync()) return const <FirebaseConfigFile>[];

    final files = <FirebaseConfigFile>[];
    // The plist may live anywhere under ios/ — Runner/, config/<flavor>/,
    // flavors/<flavor>/ are all conventions in the wild — so search rather
    // than assume one layout.
    //
    // followLinks is off deliberately: `ios/.symlinks/plugins/` points into the
    // pub cache, and following it walks into plugin *example apps* whose own
    // Firebase config would otherwise be reported as this project's.
    for (final entity
        in ios
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()) {
      if (p.basename(entity.path) != iosFileName) continue;
      if (_isExcludedIosPath(p.relative(entity.path, from: root))) continue;
      final relative = p.relative(entity.path, from: root);
      final plist = await entity.readAsString();
      files.add(
        FirebaseConfigFile(
          path: relative,
          platform: 'ios',
          sourceSet: p.basename(p.dirname(entity.path)),
          bundleOrPackageId: _plistValue(plist, 'BUNDLE_ID'),
          appId: _plistValue(plist, 'GOOGLE_APP_ID'),
          projectId: _plistValue(plist, 'PROJECT_ID'),
        ),
      );
    }
    return files;
  }

  /// Directories under `ios/` whose contents are not this project's source:
  /// dependency checkouts, build output and CocoaPods.
  static bool _isExcludedIosPath(String relative) {
    const excluded = <String>['.symlinks', 'Pods', 'build', '.dart_tool'];
    final segments = p.split(relative);
    return segments.any(excluded.contains);
  }

  /// Reports flavors whose Firebase config is present on one platform but not
  /// the other, or missing entirely.
  void _reportGaps(
    FirebaseModel model,
    Set<String> flavors,
    UncertaintyLog log,
  ) {
    if (flavors.isEmpty) return;

    for (final platform in const <String>['android', 'ios']) {
      final configured = model
          .forPlatform(platform)
          .map((f) => f.sourceSet)
          .whereType<String>()
          .toSet();
      if (configured.isEmpty) continue;

      // Only meaningful once at least one flavor is configured: a project that
      // shares one config across flavors is a legitimate choice, not a gap.
      final named = flavors.where(configured.contains).toSet();
      if (named.isEmpty) continue;

      final missing = flavors.difference(named);
      if (missing.isEmpty) continue;

      final fileName = platform == 'android' ? androidFileName : iosFileName;
      log.defect(
        field: 'firebase.$platform',
        reason:
            '${missing.length == 1 ? 'flavor' : 'flavors'} '
            '${missing.map((f) => '`$f`').join(', ')} '
            '${missing.length == 1 ? 'has' : 'have'} no $fileName, but '
            '${named.map((f) => '`$f`').join(', ')} '
            '${named.length == 1 ? 'does' : 'do'}.',
        remedy:
            'Add the missing $fileName, or confirm those flavors are '
            'meant to share one Firebase project.',
      );
    }
  }

  Future<Map<String, dynamic>> _decode(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map ? decoded.cast<String, dynamic>() : const {};
    } on FormatException {
      return const <String, dynamic>{};
    }
  }

  static String? _projectId(Map<String, dynamic> json) {
    final info = json['project_info'];
    return info is Map ? info['project_id'] as String? : null;
  }

  static String? _androidPackage(Map<String, dynamic> json) {
    final client = _firstClient(json);
    final info = client?['client_info'];
    if (info is! Map) return null;
    final android = info['android_client_info'];
    return android is Map ? android['package_name'] as String? : null;
  }

  static String? _androidAppId(Map<String, dynamic> json) {
    final client = _firstClient(json);
    final info = client?['client_info'];
    return info is Map ? info['mobilesdk_app_id'] as String? : null;
  }

  static Map<String, dynamic>? _firstClient(Map<String, dynamic> json) {
    final clients = json['client'];
    if (clients is! List || clients.isEmpty) return null;
    final first = clients.first;
    return first is Map ? first.cast<String, dynamic>() : null;
  }

  /// Pulls a value out of an XML plist without a full parse.
  ///
  /// These files are machine-generated with a fixed shape, so a targeted match
  /// is reliable here in a way it would not be for a hand-edited plist.
  static String? _plistValue(String plist, String key) {
    final match = RegExp(
      '<key>$key</key>\\s*<string>([^<]*)</string>',
    ).firstMatch(plist);
    return match?.group(1);
  }
}
