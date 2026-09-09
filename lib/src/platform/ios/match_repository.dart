import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/io/process_runner.dart';

/// One provisioning profile stored in a match repository.
class MatchProfile {
  const MatchProfile({required this.type, required this.bundleId});

  /// `appstore`, `development`, `adhoc`, `enterprise` or `developer_id` —
  /// the directory match files it under.
  final String type;

  final String bundleId;

  @override
  String toString() => '$type:$bundleId';
}

/// What a match repository holds.
///
/// Read from the *file names*, never the contents. match encrypts each file in
/// place and leaves its name alone, so the layout says which bundle ids are
/// covered without a passphrase, without decrypting anything, and without
/// talking to Apple. That is what makes this checkable on a machine that has
/// none of those things — and it means taxiway never handles the certificates
/// themselves, only the question of whether they exist.
class MatchRepositoryContents {
  const MatchRepositoryContents({
    required this.profiles,
    required this.certificateTypes,
  });

  final List<MatchProfile> profiles;

  /// The `certs/<type>` directories that hold anything.
  final Set<String> certificateTypes;

  bool get isEmpty => profiles.isEmpty && certificateTypes.isEmpty;

  Set<String> bundleIdsFor(String type) => <String>{
    for (final profile in profiles)
      if (profile.type == type) profile.bundleId,
  };

  /// Which of [wanted] have no profile of [type].
  List<String> missingFrom(Iterable<String> wanted, String type) {
    final present = bundleIdsFor(type);
    return <String>[
      for (final bundleId in wanted)
        if (!present.contains(bundleId)) bundleId,
    ];
  }
}

class MatchRepositoryFailure implements Exception {
  const MatchRepositoryFailure(this.message, {this.fixHint});
  final String message;
  final String? fixHint;

  @override
  String toString() => message;
}

/// Reads a match certificates repository without decrypting it.
abstract final class MatchRepository {
  /// The prefixes match puts on a profile file name, and the directory each
  /// lives in. Taken from `Match::Generator.profile_type_name`.
  static const Map<String, String> profilePrefixes = <String, String>{
    'AppStore': 'appstore',
    'Development': 'development',
    'AdHoc': 'adhoc',
    'InHouse': 'enterprise',
    'Direct': 'developer_id',
  };

  static const List<String> profileExtensions = <String>[
    '.mobileprovision',
    '.provisionprofile',
  ];

  /// Clones [gitUrl] shallowly and reports what is in it.
  ///
  /// Shallow because only the current state matters: the history of a
  /// certificates repository is not something taxiway has any business
  /// reading, and a full clone of one with years of rotations is slow.
  static Future<MatchRepositoryContents> read({
    required String gitUrl,
    required ProcessRunner runner,
    String branch = 'master',
    Directory? into,
  }) async {
    final directory =
        into ?? await Directory.systemTemp.createTemp('taxiway_match');
    try {
      final cloned = await runner.run('git', <String>[
        'clone',
        '--depth',
        '1',
        '--branch',
        branch,
        gitUrl,
        directory.path,
      ]);

      if (!cloned.ok) {
        throw MatchRepositoryFailure(
          'Could not read the match repository at $gitUrl.',
          fixHint: _cloneHint(cloned.output, branch),
        );
      }

      return readDirectory(directory);
    } finally {
      if (into == null && directory.existsSync()) {
        await directory.delete(recursive: true);
      }
    }
  }

  /// Reads an already-cloned repository.
  static MatchRepositoryContents readDirectory(Directory root) {
    final profiles = <MatchProfile>[];
    final certificateTypes = <String>{};

    final profilesDirectory = Directory(p.join(root.path, 'profiles'));
    if (profilesDirectory.existsSync()) {
      for (final entity in profilesDirectory.listSync(recursive: true)) {
        if (entity is! File) continue;
        final profile = parseProfilePath(
          p.relative(entity.path, from: profilesDirectory.path),
        );
        if (profile != null) profiles.add(profile);
      }
    }

    final certsDirectory = Directory(p.join(root.path, 'certs'));
    if (certsDirectory.existsSync()) {
      for (final entity in certsDirectory.listSync()) {
        if (entity is! Directory) continue;
        final hasFiles = entity.listSync().whereType<File>().isNotEmpty;
        if (hasFiles) certificateTypes.add(p.basename(entity.path));
      }
    }

    profiles.sort((a, b) => a.toString().compareTo(b.toString()));
    return MatchRepositoryContents(
      profiles: profiles,
      certificateTypes: certificateTypes,
    );
  }

  /// Turns `appstore/AppStore_com.acme.app.mobileprovision` into a profile.
  ///
  /// Matched against the known prefixes rather than split on the first
  /// underscore: the directory alone is not proof of the type, and a file that
  /// does not follow the convention is something taxiway should ignore rather
  /// than misread.
  static MatchProfile? parseProfilePath(String relative) {
    final parts = p.split(relative.replaceAll(r'\', '/'));
    if (parts.length < 2) return null;

    final directory = parts[parts.length - 2];
    final name = parts.last;

    final extension = profileExtensions.firstWhere(
      name.endsWith,
      orElse: () => '',
    );
    if (extension.isEmpty) return null;

    final withoutExtension = name.substring(0, name.length - extension.length);
    for (final entry in profilePrefixes.entries) {
      final prefix = '${entry.key}_';
      if (!withoutExtension.startsWith(prefix)) continue;

      final bundleId = withoutExtension.substring(prefix.length);
      if (bundleId.isEmpty) return null;
      // The directory is what match actually looks in, so it wins if the two
      // ever disagree.
      return MatchProfile(type: directory, bundleId: bundleId);
    }
    return null;
  }

  static String _cloneHint(String output, String branch) {
    if (output.contains('Remote branch') && output.contains('not found')) {
      return 'That repository has no "$branch" branch. Set '
          'MATCH_GIT_BRANCH, or pass --branch.';
    }
    if (output.contains('Permission denied') ||
        output.contains('Authentication failed') ||
        output.contains('could not read Username')) {
      return 'Check you can clone it yourself. On a runner this needs '
          'MATCH_GIT_PRIVATE_KEY or MATCH_GIT_BASIC_AUTHORIZATION.';
    }
    if (output.contains('not found') || output.contains('does not exist')) {
      return 'Check the URL. `taxiway setup ios-signing --create` can '
          'initialise an empty repository.';
    }
    return 'Check the URL and that you have access to it.';
  }
}
