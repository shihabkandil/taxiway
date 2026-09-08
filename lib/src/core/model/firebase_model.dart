/// One `google-services.json` or `GoogleService-Info.plist` found on disk.
class FirebaseConfigFile {
  const FirebaseConfigFile({
    required this.path,
    required this.platform,
    this.bundleOrPackageId,
    this.appId,
    this.projectId,
    this.sourceSet,
  });

  /// Relative path.
  final String path;

  /// `android` or `ios`.
  final String platform;

  /// `package_name` on Android, `BUNDLE_ID` on iOS.
  final String? bundleOrPackageId;

  /// `mobilesdk_app_id` / `GOOGLE_APP_ID`.
  final String? appId;

  final String? projectId;

  /// The directory it was found under, which is how it is correlated with a
  /// flavor — `android/app/src/<sourceSet>/` or `ios/<dir>/`.
  final String? sourceSet;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'path': path,
    'platform': platform,
    if (sourceSet != null) 'sourceSet': sourceSet,
    if (bundleOrPackageId != null) 'bundleOrPackageId': bundleOrPackageId,
    if (appId != null) 'appId': appId,
    if (projectId != null) 'projectId': projectId,
  };
}

/// Firebase configuration discovered in the project.
class FirebaseModel {
  const FirebaseModel({
    this.configFiles = const <FirebaseConfigFile>[],
    this.hasFirebaseJson = false,
    this.hasFirebaseOptionsDart = false,
  });

  final List<FirebaseConfigFile> configFiles;
  final bool hasFirebaseJson;

  /// `lib/firebase_options.dart`, written by flutterfire.
  final bool hasFirebaseOptionsDart;

  bool get inUse =>
      configFiles.isNotEmpty || hasFirebaseJson || hasFirebaseOptionsDart;

  Iterable<FirebaseConfigFile> forPlatform(String platform) =>
      configFiles.where((f) => f.platform == platform);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'hasFirebaseJson': hasFirebaseJson,
    'hasFirebaseOptionsDart': hasFirebaseOptionsDart,
    'configFiles':
        (configFiles.toList()..sort((a, b) => a.path.compareTo(b.path)))
            .map((f) => f.toJson())
            .toList(),
  };
}
