import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/managed/content_hash.dart';
import '../core/managed/lock_file.dart';
import 'generated_file.dart';

/// What became of one file taxiway used to produce and no longer does.
enum OrphanOutcome {
  /// Deleted. Its content still matched what taxiway wrote, so it held nothing
  /// the user authored.
  removed,

  /// Left on disk and released. Somebody edited it, so it holds a decision;
  /// taxiway stops managing it rather than destroying it.
  released,

  /// `--dry-run`: this is what would happen.
  wouldRemove,
  wouldRelease;

  bool get isRemoval =>
      this == OrphanOutcome.removed || this == OrphanOutcome.wouldRemove;
}

class OrphanResult {
  const OrphanResult({required this.path, required this.outcome});

  final String path;
  final OrphanOutcome outcome;

  /// One line for the report.
  String get detail => switch (outcome) {
    OrphanOutcome.removed ||
    OrphanOutcome.wouldRemove => 'no longer described by taxiway.yaml',
    OrphanOutcome.released || OrphanOutcome.wouldRelease =>
      'no longer described by taxiway.yaml, but you have edited it — '
          'left in place and no longer managed',
  };
}

/// Why a sweep did not run.
enum SweepSkipReason {
  /// More than one app: paths are not app-scoped, so an orphan of one app
  /// cannot be told from a live file of another.
  monorepo,

  /// The user passed `--no-prune`.
  disabled,
}

class SweepReport {
  const SweepReport({this.results = const <OrphanResult>[], this.skipped});

  final List<OrphanResult> results;
  final SweepSkipReason? skipped;

  bool get isEmpty => results.isEmpty;
}

/// Removes files taxiway generated and no longer produces.
///
/// The whole difficulty is that "this run did not produce it" has several
/// causes and only one of them means "the config stopped asking for it". A
/// partial run (`taxiway generate flavors`) produces no fastlane files; a
/// generator whose template is missing produces nothing at all. Treating either
/// as a removal would delete working files.
///
/// So the sweep never reasons from absence alone. A file is a candidate only
/// when a generator that *ran in this invocation* claims it via
/// [Generator.owns] and reports, via [Generator.canDetermineOwnership], that
/// its silence is meaningful. See `docs/orphan-cleanup.md`.
abstract final class OrphanSweep {
  /// Finds and disposes of orphans left by [generators] for [app].
  ///
  /// [produced] is every path this run rendered — including files the writer
  /// skipped, such as create-once scaffolding, because the generator still
  /// declared them.
  static Future<SweepReport> run({
    required String root,
    required LockFile lock,
    required ResolvedApp app,
    required List<Generator> generators,
    required Iterable<String> produced,
    required int appCount,
    bool dryRun = false,
    bool enabled = true,
  }) async {
    if (!enabled) {
      return const SweepReport(skipped: SweepSkipReason.disabled);
    }
    // Deliberate, and temporary: `dart_defines/dev.json` is not attributable to
    // one app today, so a monorepo cannot be swept safely.
    if (appCount > 1) {
      return const SweepReport(skipped: SweepSkipReason.monorepo);
    }

    final sweepers = <Generator>[
      for (final generator in generators)
        if (generator.canDetermineOwnership(app)) generator,
    ];
    if (sweepers.isEmpty) return const SweepReport();

    final producedPaths = produced.map(_normalise).toSet();
    final results = <OrphanResult>[];

    // Snapshot first: `lock.files` is a view over the map this loop mutates.
    for (final entry in lock.files.values.toList()) {
      // Only ever taxiway's own work. An adopted file is the user's, handed
      // over on their terms; an unmanaged one was never ours.
      if (entry.ownership != Ownership.generated) continue;

      final path = _normalise(entry.path);
      if (producedPaths.contains(path)) continue;
      if (!sweepers.any((g) => g.owns(path))) continue;

      final file = File(p.join(root, p.joinAll(p.posix.split(path))));
      if (!file.existsSync()) {
        // Already gone; just stop claiming it.
        if (!dryRun) lock.remove(path);
        continue;
      }

      // Deletable only when we can prove the file still holds exactly what
      // taxiway wrote. A missing recorded hash is not proof of anything, so it
      // counts as edited: never delete on the strength of not knowing.
      final contents = await file.readAsString();
      final edited = !ContentHash.matches(entry.hash, contents);

      if (edited) {
        if (!dryRun) {
          // Released rather than deleted, and released *once*: downgrading the
          // entry means the next run says nothing about it, because a tool
          // that reports the same thing every time is one people stop reading.
          lock.record(
            LockEntry(
              path: path,
              ownership: Ownership.unmanaged,
              mode: entry.mode,
            ),
          );
        }
        results.add(
          OrphanResult(
            path: path,
            outcome: dryRun
                ? OrphanOutcome.wouldRelease
                : OrphanOutcome.released,
          ),
        );
        continue;
      }

      if (!dryRun) {
        await file.delete();
        lock.remove(path);
      }
      results.add(
        OrphanResult(
          path: path,
          outcome: dryRun ? OrphanOutcome.wouldRemove : OrphanOutcome.removed,
        ),
      );
    }

    results.sort((a, b) => a.path.compareTo(b.path));
    return SweepReport(results: results);
  }

  static String _normalise(String path) =>
      p.posix.normalize(path.replaceAll(r'\', '/'));
}
