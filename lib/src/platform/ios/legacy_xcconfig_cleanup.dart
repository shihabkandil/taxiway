import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/managed/lock_file.dart';

/// Removes the per-flavor xcconfigs shipway used to write.
///
/// An earlier version generated `ios/Flutter/<flavor>.xcconfig` and attached it
/// to each `<BuildType>-<flavor>` configuration as its base configuration. That
/// displaced the stock `Debug.xcconfig`/`Release.xcconfig`, and with them
/// `Generated.xcconfig` — so a flavored build compiled `lib/main.dart` whatever
/// `-t` said, dropped every `--dart-define`, and produced an Info.plist with no
/// `CFBundleVersion`. The configurations are repointed by the bridge; this
/// deletes the files they used to point at, so a repaired project is left with
/// no misleading leftovers.
///
/// Deliberately narrow. It removes a file only when shipway generated it, it is
/// still byte-for-byte what shipway wrote, and it sits at exactly the legacy
/// path for a flavor in this config. Anything else — a file the user has since
/// edited, or one that was theirs to begin with — is left alone and reported,
/// because deleting somebody's build settings is far worse than leaving a stale
/// file behind.
abstract final class LegacyXcconfigCleanup {
  static const String directory = 'ios/Flutter';

  static String pathFor(String flavor) => '$directory/$flavor.xcconfig';

  /// Deletes what it safely can, returning the paths it removed and the paths
  /// it deliberately left.
  static Future<LegacyXcconfigResult> run({
    required String root,
    required LockFile lock,
    required Iterable<String> flavors,
  }) async {
    final removed = <String>[];
    final kept = <String>[];

    for (final flavor in flavors) {
      final relative = pathFor(flavor);
      final file = File(p.join(root, p.joinAll(p.posix.split(relative))));
      if (!file.existsSync()) continue;

      final entry = lock[relative];
      if (entry?.ownership != Ownership.generated) {
        kept.add(relative);
        continue;
      }

      // Edited since shipway wrote it, so it now holds somebody's decision.
      if (lock.hasDrifted(relative, await file.readAsString())) {
        kept.add(relative);
        continue;
      }

      await file.delete();
      lock.remove(relative);
      removed.add(relative);
    }

    return LegacyXcconfigResult(removed: removed, kept: kept);
  }
}

class LegacyXcconfigResult {
  const LegacyXcconfigResult({required this.removed, required this.kept});

  /// Paths deleted because shipway wrote them and nobody had changed them.
  final List<String> removed;

  /// Paths left in place, and now referenced by nothing.
  final List<String> kept;

  bool get isEmpty => removed.isEmpty && kept.isEmpty;
}
