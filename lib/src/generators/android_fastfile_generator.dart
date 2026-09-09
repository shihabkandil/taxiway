import '../core/config/taxiway_config.dart';
import '../core/secrets/secret_names.dart';
import 'fastlane_ruby.dart';
import 'generated_file.dart';

/// Writes `android/fastlane/Fastfile`.
///
/// The Android half of the same division of labour as iOS: `flutter build`
/// produces the artifact and fastlane only uploads it. There is no Android
/// equivalent of the gym trap — `supply` has never built anything — so the
/// shape is simply build-then-upload.
class AndroidFastfileGenerator extends Generator {
  const AndroidFastfileGenerator();

  @override
  String get name => 'android-fastfile';

  @override
  String get description => 'The Android release lanes.';

  static const String path = 'android/fastlane/Fastfile';

  /// The environment variable holding a *path* to the Play service-account
  /// JSON, used when the config names no variable of its own.
  static const String playKeyEnv = SecretNames.playServiceAccountPath;

  /// Which variable the play lane reads, and how it hands it to `supply`.
  ///
  /// `targets.play.service_account_ref` names a variable holding the JSON
  /// itself, so it goes to `json_key_data`; the default convention is a path,
  /// which goes to `json_key`. Getting this wrong is not visible in a generated
  /// file — the pre-flight passes and `supply` fails at the upload with an
  /// authentication error naming nothing.
  static ({String name, String parameter}) playKey(ResolvedApp app) {
    final contentRef = app.play?.serviceAccountRef;
    return contentRef == null
        ? (name: playKeyEnv, parameter: 'json_key')
        : (name: contentRef, parameter: 'json_key_data');
  }

  /// The environment variable naming the Firebase service-account JSON.
  ///
  /// A file path rather than the deprecated CI token: Firebase App
  /// Distribution rejects refresh-token auth now.
  static const String firebaseKeyEnv = SecretNames.firebaseServiceAccountPath;

  @override
  bool owns(String path) => path == AndroidFastfileGenerator.path;

  @override
  List<GeneratedFile> render(ResolvedApp app) {
    // Without a package name the lanes have nothing to upload against, and a
    // Fastfile that names no app is worse than none.
    if (!app.hasFlavors || app.androidApplicationId == null) {
      return const <GeneratedFile>[];
    }
    return <GeneratedFile>[
      GeneratedFile.full(
        path: path,
        contents: _render(app),
        description: 'Android build and release lanes',
      ),
    ];
  }

  String _render(ResolvedApp app) => <String>[
    FastlaneRuby.header('android'),
    FastlaneRuby.flavorTable(
      app,
      (flavor) => <String, String>{
        'package_name': flavor.androidApplicationId ?? '',
      },
    ),
    FastlaneRuby.helpers(),
    FastlaneRuby.flutterBuild(),
    _artifactHelper(),
    'platform :android do',
    _buildLane(app),
    _playLane(app),
    if (app.firebase?.androidAppIdRef != null) _firebaseLane(app),
    'end',
  ].join('\n');

  /// Where Flutter writes each Android artifact.
  ///
  /// Confirmed against a real flavored project; the `<flavor>Release`
  /// directory name is Gradle's variant naming, not something to guess at.
  String _artifactHelper() => r'''
def artifact_path(flavor, type)
  case type
  when "appbundle"
    root_path("build/app/outputs/bundle/#{flavor}Release/app-#{flavor}-release.aab")
  when "apk"
    root_path("build/app/outputs/flutter-apk/app-#{flavor}-release.apk")
  else
    UI.user_error!("Unsupported artifact #{type.inspect}. Expected appbundle or apk.")
  end
end

def mapping_path(flavor)
  root_path("build/app/outputs/mapping/#{flavor}Release/mapping.txt")
end
''';

  String _buildLane(ResolvedApp app) {
    final signing = app.androidSigning;
    // key.properties holds the keystore passwords and is git-ignored, so it is
    // the one file a fresh checkout reliably lacks. Saying so up front beats a
    // Gradle error about a null signingConfig.
    final keyPropertiesGuard = signing == null
        ? ''
        : '''
    require_file(
      root_path("android/key.properties"),
      "Create it locally, or generate it from the ${signing.keystoreRef ?? 'ANDROID_KEYSTORE_BASE64'} secret on CI."
    )
''';

    return '''
  desc "Build a signed release artifact for a flavor"
  lane :build do |options|
    flavor = require_flavor(options)
    config = flavor_config(flavor)
    type = options.fetch(:type, "appbundle")

$keyPropertiesGuard
    flutter_build(type: type, flavor: flavor, entrypoint: config[:entrypoint])

    artifact = artifact_path(flavor, type)
    # A Flutter build that reports success and produces nothing means the
    # flavor exists in Gradle under a different name than the config thinks.
    require_file(artifact, "The build reported success but produced no artifact.")
    artifact
  end
''';
  }

  String _playLane(ResolvedApp app) {
    final play = app.play;
    final track = (play?.track ?? PlayTrack.internal).name;
    final status = _statusName(play?.releaseStatus ?? PlayReleaseStatus.draft);
    final artifact = (play?.artifact ?? PlayArtifact.aab).name;
    final isAab = artifact == 'aab';
    final rollout = play?.rollout;
    final key = playKey(app);

    return '''
  desc "Build and upload to the Play Store $track track"
  lane :play do |options|
    flavor = require_flavor(options)
    config = flavor_config(flavor)
    require_env("${key.name}")

    artifact = build(flavor: flavor, type: "${isAab ? 'appbundle' : 'apk'}")

    next UI.important("dry_run: would upload #{artifact}") if options[:dry_run]

    upload_to_play_store(
      package_name: config[:package_name],
      ${key.parameter}: ENV.fetch("${key.name}"),
      track: options.fetch(:track, "$track"),
      release_status: "$status",${rollout == null ? '' : '\n      rollout: "$rollout",'}
      ${isAab ? 'aab' : 'apk'}: artifact,
      mapping_paths: File.exist?(mapping_path(flavor)) ? [mapping_path(flavor)] : nil,
      # Metadata belongs to whoever writes the store listing, not to a build.
      skip_upload_metadata: true,
      skip_upload_images: true,
      skip_upload_screenshots: true,
      skip_upload_${isAab ? 'apk' : 'aab'}: true
    )
  end
''';
  }

  String _firebaseLane(ResolvedApp app) {
    final appIdRef = app.firebase!.androidAppIdRef!;
    final groups = app.firebase!.groups;
    return '''
  desc "Build and upload to Firebase App Distribution"
  lane :firebase do |options|
    flavor = require_flavor(options)
    require_env("$appIdRef", "$firebaseKeyEnv")

    artifact = build(flavor: flavor, type: options.fetch(:type, "apk"))

    next UI.important("dry_run: would upload #{artifact}") if options[:dry_run]

    firebase_app_distribution(
      # A service-account file, not the deprecated CI token, which App
      # Distribution no longer accepts.
      service_credentials_file: ENV.fetch("$firebaseKeyEnv"),
      app: ENV.fetch("$appIdRef"),
      android_artifact_path: artifact,
      android_artifact_type: options.fetch(:type, "apk").upcase,
      groups: "${groups.isEmpty ? 'testers' : groups.join(',')}",
      release_notes: "#{flavor} #{last_git_commit[:abbreviated_commit_hash]}"
    )
  end
''';
  }

  /// `supply` spells the status in camelCase, unlike every other option.
  static String _statusName(PlayReleaseStatus status) =>
      status == PlayReleaseStatus.inProgress ? 'inProgress' : status.name;
}
