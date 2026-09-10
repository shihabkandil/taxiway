import '../core/config/taxiway_config.dart';
import '../core/secrets/secret_names.dart';

/// Renders the Ruby that decides a build number.
///
/// Ruby rather than Dart because one of the three strategies means asking App
/// Store Connect or Google Play, which only fastlane can do. Computing the
/// other two in Dart would leave two implementations of the same question, and
/// the failure when they disagree is a duplicate build number in a store — an
/// error whose message names neither implementation.
///
/// So there is one answer, in the place that can actually reach a store.
abstract final class VersionResolver {
  /// The version name and build number a release lane should use.
  ///
  /// `version_name` always comes from `pubspec.yaml`: a marketing version is a
  /// decision, not something to derive. Only the build number varies.
  static String render({
    required VersioningStrategy strategy,
    required bool syncIosAndroid,
    required String platform,
  }) =>
      '''
${_pubspecReader()}
${_buildNumber(strategy, platform)}
${_syncNote(syncIosAndroid)}''';

  /// Reads `version: x.y.z+n` without a YAML parser.
  ///
  /// The line has a fixed shape and pulling in a gem to read one field would be
  /// another pin to keep satisfiable on the Ruby floor.
  static String _pubspecReader() => r'''
def pubspec_version
  @pubspec_version ||= begin
    match = File.read(root_path("pubspec.yaml"))
                .match(/^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$/)
    unless match
      UI.user_error!("Could not read `version: x.y.z+n` from pubspec.yaml. " \
                     "Every release needs a version to claim.")
    end
    { name: match[1], code: match[2] }
  end
end

def version_name(requested = nil)
  value = requested.to_s.strip
  value.empty? ? pubspec_version[:name] : value
end
''';

  static String _buildNumber(VersioningStrategy strategy, String platform) =>
      switch (strategy) {
        VersioningStrategy.increment => _incrementStrategy(),
        VersioningStrategy.timestamp => _timestampStrategy(),
        VersioningStrategy.remote =>
          platform == 'ios' ? _remoteIosStrategy() : _remoteAndroidStrategy(),
      };

  static String _incrementStrategy() => r'''
# versioning.strategy: increment — pubspec is the source of truth, and bumping
# it is a commit somebody makes deliberately.
def build_number(requested = nil, **)
  value = requested.to_s.strip
  value.empty? ? pubspec_version[:code] : value
end
''';

  static String _timestampStrategy() => r'''
# versioning.strategy: timestamp — monotonic without asking anything, which is
# what makes it work offline and on a fresh checkout.
def build_number(requested = nil, **)
  value = requested.to_s.strip
  return value unless value.empty?

  Time.now.utc.strftime("%y%m%d%H%M")
end
''';

  static String _remoteIosStrategy() => r'''
# versioning.strategy: remote — ask App Store Connect what the last build was.
# The store is the only thing that knows for certain, and a number derived from
# anything else is a guess that fails at upload with a message naming neither.
def build_number(requested = nil, app_identifier:, api_key: nil)
  value = requested.to_s.strip
  return value unless value.empty?

  latest = latest_testflight_build_number(
    app_identifier: app_identifier,
    api_key: api_key,
    # A brand new app has no builds; starting at 0 makes the first one 1.
    initial_build_number: 0
  )
  (latest.to_i + 1).to_s
end
''';

  static String _remoteAndroidStrategy() =>
      '''
# versioning.strategy: remote — ask Play for the codes already on the track.
def build_number(requested = nil, package_name:, track: "internal", **)
  value = requested.to_s.strip
  return value unless value.empty?

  codes = google_play_track_version_codes(
    package_name: package_name,
    track: track,
    json_key: ENV.fetch("${SecretNames.playServiceAccountPath}")
  )
  # `.max`, not `.first`: the API does not promise an order, and picking the
  # wrong element produces a code Play rejects as non-increasing. An empty
  # track gives nil, which becomes 0, so the first upload is 1.
  ((codes || []).map(&:to_i).max.to_i + 1).to_s
end
''';

  static String _syncNote(bool sync) => sync
      ? '# versioning.sync_ios_android is on: each release resolves the build\n'
            '# number once and both platforms are given the same one.\n'
      : '# versioning.sync_ios_android is off: each platform numbers itself.\n';
}
