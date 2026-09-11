/// One lane declared in a Fastfile.
class FastlaneLane {
  const FastlaneLane({
    required this.name,
    required this.platform,
    this.isPrivate = false,
  });

  final String name;

  /// `ios`, `android`, or null for a lane outside any platform block.
  final String? platform;

  final bool isPrivate;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    if (platform != null) 'platform': platform,
    if (isPrivate) 'private': true,
  };
}

/// What an existing fastlane setup says.
///
/// Read statically — shipway never executes a Fastfile. A Fastfile is arbitrary
/// Ruby, so fidelity here is explicitly partial: whatever is not a literal
/// becomes an [Uncertainty] rather than a guess.
class FastlaneModel {
  const FastlaneModel({
    required this.directory,
    this.lanes = const <FastlaneLane>[],
    this.appIdentifier,
    this.teamId,
    this.itcTeamId,
    this.appleId,
    this.matchGitUrl,
    this.matchStorageMode,
    this.matchType,
    this.environmentVariables = const <String>{},
    this.plugins = const <String>[],
    this.hasGemfile = false,
    this.hasGemfileLock = false,
  });

  /// Relative path of the fastlane directory, e.g. `ios/fastlane`.
  final String directory;

  final List<FastlaneLane> lanes;

  /// From the Appfile.
  final String? appIdentifier;
  final String? teamId;
  final String? itcTeamId;
  final String? appleId;

  /// From the Matchfile.
  final String? matchGitUrl;
  final String? matchStorageMode;
  final String? matchType;

  /// Every `ENV['NAME']` referenced anywhere in the setup.
  ///
  /// Harvested so import can seed the config's `*_ref` fields with names the
  /// user already chose, instead of asking them again.
  final Set<String> environmentVariables;

  final List<String> plugins;
  final bool hasGemfile;
  final bool hasGemfileLock;

  List<String> get laneNames =>
      lanes.map((l) => l.name).toList(growable: false);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'directory': directory,
    'lanes': lanes.map((l) => l.toJson()).toList(),
    if (appIdentifier != null) 'appIdentifier': appIdentifier,
    if (teamId != null) 'teamId': teamId,
    if (itcTeamId != null) 'itcTeamId': itcTeamId,
    if (appleId != null) 'appleId': appleId,
    if (matchGitUrl != null) 'matchGitUrl': matchGitUrl,
    if (matchStorageMode != null) 'matchStorageMode': matchStorageMode,
    if (matchType != null) 'matchType': matchType,
    'environmentVariables': environmentVariables.toList()..sort(),
    'plugins': plugins,
    'hasGemfile': hasGemfile,
    'hasGemfileLock': hasGemfileLock,
  };
}
